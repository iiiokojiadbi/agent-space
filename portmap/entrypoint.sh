#!/bin/bash
set -e

MAP=/run/services.map
CTRL_GLOB='/run/ssh-control/cm-*.sock'

# Обратные форварды — то, что эта машина отдаёт дальней стороне. Список
# постоянный, поэтому живёт здесь, а не в карте сервисов.
#
# Держит их тот же цикл, что и прямые, и это принципиально. RemoteForward из
# ssh_config отрабатывает ровно один раз — в момент установки соединения. Если
# порт на дальней стороне в этот момент ещё держала недобитая сессия, форвард
# молча не встаёт: ExitOnForwardFailure no оставляет туннель живым, а порта там
# нет. Задним числом он не появится, и снаружи это выглядит как исправный
# туннель без докера и без выхода в сеть у дальней стороны.
#
# Формат: <порт>:<цель>[|<цель>...], цель — <адрес>[:<порт>]. Порт цели
# указывается, только если отличается от порта на дальней стороне.
#
# Несколько целей через `|` — кандидаты по порядку. Берётся первая, которая
# принимает соединение; последняя — без проверки, как запасная. Выбор
# перепроверяется каждый проход цикла, и форвард переключается сам.
#
# 8089 — выход в сеть для дальней стороны, своего у неё нет. Первым идёт
# отдельный прокси на этой машине: пока он запущен, дальняя сторона ходит через
# него. Не запущен — через встроенный прокси Docker Desktop, который ходит наружу
# по системным настройкам прокси, включая автонастройку. Отдельный прокси нужен
# там, где автонастройки нет, а корпоративные адреса нужны; Docker Desktop
# избавляет от отдельного процесса там, где она есть. Переключение — запуском
# или остановкой отдельного прокси, больше ничего трогать не нужно.
REVERSE=${REVERSE_FORWARDS:-"2375:127.0.0.1 8089:host.docker.internal|http.docker.internal:3128"}

trap 'echo "[portmap] terminating"; exit 0' TERM INT

echo "[portmap] waiting for shared ControlMaster socket..."
while ! compgen -G "$CTRL_GLOB" >/dev/null; do
	sleep 1
done
echo "[portmap] ControlMaster ready"

if [ -d "$MAP" ]; then
	echo "[portmap] WARNING: $MAP is a directory — забыл создать services.map из services.map.example?"
fi

desired_ports() {
	[ -f "$MAP" ] || return 0
	grep -Ev '^[[:space:]]*(#|$)' "$MAP" | while read -r _ port _; do
		[ -n "$port" ] && echo "$port"
	done
}

master_alive() { ssh -O check bpi >/dev/null 2>&1; }

# <адрес>[:<порт>] <порт по умолчанию> -> <адрес>:<порт>. Без порта цели номер
# совпадает с номером на дальней стороне: одинаковые проще искать в логах.
target_of() {
	local t=$1
	[ "${t#*:}" = "$t" ] && t="$t:$2"
	echo "$t"
}

# Все цели записи построчно, как «<порт> <адрес>:<порт>».
all_targets() {
	local port=${1%%:*} t
	local -a list
	IFS='|' read -ra list <<< "${1#*:}"
	for t in "${list[@]}"; do
		[ -n "$t" ] && echo "$port $(target_of "$t" "$port")"
	done
	return 0
}

reachable() { timeout 2 bash -c "exec 3<>/dev/tcp/${1%:*}/${1##*:}" 2>/dev/null; }

# Выбранная цель записи, «<порт> <адрес>:<порт>»: первая принимающая соединение,
# иначе последняя без проверки.
choose_target() {
	local port=${1%%:*} t
	local -a list=()
	while read -r _ t; do
		list+=("$t")
	done < <(all_targets "$1")
	for t in "${list[@]:0:${#list[@]}-1}"; do
		reachable "$t" && { echo "$port $t"; return; }
	done
	echo "$port ${list[-1]}"
}

# <порт> <адрес>:<порт> -> аргумент для -R.
#
# Адрес привязки задан явно, и это не косметика. Без него sshd вешает форвард на
# оба стека сразу, а успехом считает привязку хотя бы к одному: занят IPv4 —
# форвард встаёт только на IPv6, `ssh -O forward` возвращает ноль, и порт с виду
# есть. Обращения на 127.0.0.1 при этом молчат, а цикл больше не повторяет
# попытку — он же получил успех. С явным адресом занятый порт даёт честную
# ошибку, и следующая попытка проходит, когда порт освободится.
reverse_spec() { echo "127.0.0.1:$1:$2"; }

# Снять форварды, оставшиеся от прошлого экземпляра контейнера: мастер их переживает,
# и без очистки active[] после рестарта пуст, а forward на уже занятый порт падает —
# причём занят он собственным же осиротевшим форвардом, поэтому на хосте его не видно
# ни в lsof, ни в netstat (слушает sshd мастера, а не отдельный процесс).
#
# Вызывается при КАЖДОМ восстановлении соединения, а не однократно на старте: если
# мастера в момент запуска не было, единичная очистка молча пропускалась, и потом
# форварды не поднимались до тех пор, пока мастер сам не переподключится.
#
# Обратные снимаются по всем кандидатам, а не только по текущему выбору: отмена
# в ssh сверяет цель целиком, и форвард на другого кандидата она не заденет.
cleanup_stale() {
	master_alive || return 0
	local p r port t
	for p in $(desired_ports); do
		ssh -O cancel -L "127.0.0.1:$p:127.0.0.1:$p" bpi 2>/dev/null || true
	done
	for r in $REVERSE; do
		while read -r port t; do
			ssh -O cancel -R "$(reverse_spec "$port" "$t")" bpi 2>/dev/null || true
		done < <(all_targets "$r")
	done
}

# Опечатка в записи не должна молча выключать форвард: без цели choose_target
# ничего не вернёт, и запись будет пропускаться каждый проход без единого слова.
checked=""
for r in $REVERSE; do
	if [[ "$r" == [0-9]*:?* ]] && [ -n "$(all_targets "$r")" ]; then
		checked+="$r "
	else
		echo "[portmap] WARNING: обратный форвард '$r' пропущен — формат <порт>:<цель>[|<цель>...]"
	fi
done
REVERSE=$checked

# Отказ обратного форварда повторяется в логе с этим интервалом, а не пишется
# один раз: 8089 — единственный выход дальней стороны в сеть, и одна строка,
# за которой тишина, прячет затянувшуюся поломку.
FAIL_REPEAT=300

declare -A active failed active_r failed_r failed_r_at
master_was_down=1

while true; do
	if ! master_alive; then
		echo "[portmap] master not reachable (мёртв или нет прав на сокет — проверь uid), waiting..."
		active=()
		failed=()
		active_r=()
		failed_r=()
		master_was_down=1
		sleep 5
		continue
	fi

	# соединение только что вернулось — подчистить хвосты прошлой жизни
	if [ "$master_was_down" = "1" ]; then
		cleanup_stale
		master_was_down=0
	fi

	declare -A want=()
	while read -r p; do
		[ -n "$p" ] && want[$p]=1
	done < <(desired_ports)

	# добавить новые
	for p in "${!want[@]}"; do
		[ -n "${active[$p]:-}" ] && continue
		# stderr ssh не глушим: без него причина отказа теряется, и остаётся гадать
		if err=$(ssh -O forward -L "127.0.0.1:$p:127.0.0.1:$p" bpi 2>&1); then
			echo "[portmap] +forward $p"
			active[$p]=1
			unset 'failed[$p]'
		elif [ -z "${failed[$p]:-}" ]; then
			# логируем один раз, а не каждые 5с
			echo "[portmap] failed to forward $p: ${err:-причина неизвестна, ssh промолчал}"
			failed[$p]=1
		fi
	done

	# обратные: список постоянный, но цель записи с кандидатами может смениться.
	# Повтор каждые пять секунд заодно лечит занятый порт — недобитая сессия на
	# дальней стороне отпускает его сама, и следующая попытка проходит
	for r in $REVERSE; do
		read -r port t < <(choose_target "$r") || continue
		# Один неответ пробы ещё не повод уводить выход: переключение рвёт
		# дальней стороне путь посреди работы. Смена цели подтверждается
		# повторной пробой.
		if [ -n "${active_r[$port]:-}" ] && [ "${active_r[$port]}" != "$t" ]; then
			sleep 1
			read -r port t < <(choose_target "$r") || continue
		fi
		[ "${active_r[$port]:-}" = "$t" ] && continue
		if [ -n "${active_r[$port]:-}" ]; then
			echo "[portmap] -reverse $port -> ${active_r[$port]}"
			unset 'active_r[$port]'
		fi
		# Порт может держать форвард на другую цель — прошлый выбор или хвост,
		# который не снялся в прошлый раз. Отмена сверяет цель целиком, поэтому
		# снимаются все остальные кандидаты, и так на каждой попытке: иначе
		# одна неудачная отмена оставила бы порт занятым навсегда.
		while read -r _ o; do
			[ "$o" = "$t" ] || ssh -O cancel -R "$(reverse_spec "$port" "$o")" bpi 2>/dev/null || true
		done < <(all_targets "$r")
		if err=$(ssh -O forward -R "$(reverse_spec "$port" "$t")" bpi 2>&1); then
			echo "[portmap] +reverse $port -> $t"
			active_r[$port]=$t
			unset 'failed_r[$port]' 'failed_r_at[$port]'
		elif [ "${failed_r[$port]:-}" != "$t" ] || (( SECONDS - ${failed_r_at[$port]:-0} >= FAIL_REPEAT )); then
			echo "[portmap] failed to reverse-forward $port -> $t: ${err:-причина неизвестна, ssh промолчал}"
			failed_r[$port]=$t
			failed_r_at[$port]=$SECONDS
		fi
	done

	# снять исчезнувшие
	for p in "${!active[@]}"; do
		if [ -z "${want[$p]:-}" ]; then
			if err=$(ssh -O cancel -L "127.0.0.1:$p:127.0.0.1:$p" bpi 2>&1); then
				echo "[portmap] -forward $p"
				unset 'active[$p]'
			else
				echo "[portmap] failed to cancel $p, keep tracking: ${err:-причина неизвестна}"
			fi
		fi
	done

	sleep 5
done
