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
# Формат: <порт>:<адрес>[:<порт цели>]. Порт цели указывается, только если
# отличается от порта на дальней стороне.
#
# Цель обратного форварда за время жизни мастера не меняется, и это не
# упрощение, а требование. Клиент ssh запоминает цель форварда до ответа
# сервера и при отказе — порт ещё занят недобитой сессией — эту запись не
# стирает. Входящее соединение он ведёт по первой записи с тем же портом, а
# отмена снимает тоже первую, а не запрошенную. Пока цель одна, такие записи
# безвредны: все ведут в одно место. Смени цель на лету — и соединения молча
# уйдут по старой записи, хотя в логе будет новая. Поэтому выбор выхода сделан
# не здесь, а дальше, в egress.
#
# 8089 — выход в сеть для дальней стороны, своего у неё нет. Ведёт в egress.
REVERSE=${REVERSE_FORWARDS:-"2375:127.0.0.1 8089:127.0.0.1:28089"}

# egress — ретранслятор выхода. Ведёт соединения в отдельный прокси на этой
# машине, если он запущен, иначе во встроенный прокси Docker Desktop, который
# ходит наружу по системным настройкам прокси, включая автонастройку. Отдельный
# прокси нужен там, где автонастройки нет, а корпоративные адреса нужны; Docker
# Desktop избавляет от отдельного процесса там, где она есть. Переключение —
# запуском или остановкой отдельного прокси, больше ничего.
#
# Запущен ли отдельный прокси, проверяет этот цикл раз в проход и пишет в
# EGRESS_STATE; egress только читает. Смена выхода поэтому доходит за один
# проход, зато к отдельному прокси не стучатся лишний раз на каждое соединение.
EGRESS_LISTEN=127.0.0.1:28089
EGRESS_PRIMARY=host.docker.internal:8089
EGRESS_FALLBACK=http.docker.internal:3128
EGRESS_STATE=/tmp/egress-via
# egress-connect получает их окружением, а не аргументами: socat делит адрес
# EXEC по двоеточиям, и host:port в командной строке ломает его разбор.
export EGRESS_PRIMARY EGRESS_FALLBACK EGRESS_STATE

# Отказ обратного форварда повторяется в логе с этим интервалом, а не пишется
# один раз: 8089 — единственный выход дальней стороны в сеть, и одна строка,
# за которой тишина, прячет затянувшуюся поломку.
FAIL_REPEAT=300

egress_pid=
egress_failed_at=
egress_via=

# nofork: соединение уходит в egress-connect напрямую, без второго процесса
# socat между ними. Почему это важно для закрытия соединений — там же.
start_egress() {
	socat "TCP-LISTEN:${EGRESS_LISTEN##*:},bind=${EGRESS_LISTEN%:*},reuseaddr,fork" \
		EXEC:/usr/local/bin/egress-connect,nofork &
	egress_pid=$!
}

# Упавший socat поднимается заново на каждом проходе. Причина обычно одна —
# порт занят, — и в лог она попадает не каждые пять секунд, а раз в FAIL_REPEAT:
# это тот же критичный путь, что и 8089.
keep_egress() {
	[ -n "$egress_pid" ] && kill -0 "$egress_pid" 2>/dev/null && return 0
	if [ -n "$egress_pid" ] && { [ -z "$egress_failed_at" ] || (( SECONDS - egress_failed_at >= FAIL_REPEAT )); }; then
		echo "[portmap] egress exited, restarting (порт ${EGRESS_LISTEN} занят?)"
		egress_failed_at=$SECONDS
	fi
	start_egress
	sleep 0.2
	if kill -0 "$egress_pid" 2>/dev/null; then egress_failed_at=; fi
}

# Запущен ли отдельный прокси. Таймаут обязателен: зависший прокси или
# потерянный пакет иначе держали бы подключение минутами, и цикл встал бы.
# Файл пишется через переименование, чтобы egress не прочёл его наполовину.
choose_egress() {
	local via=docker
	timeout 1 bash -c "exec 3<>/dev/tcp/${EGRESS_PRIMARY%:*}/${EGRESS_PRIMARY##*:}" 2>/dev/null && via=primary
	[ "$via" = "$egress_via" ] && return 0
	# Под `set -e` неудачная запись уронила бы весь portmap вместе с форвардами.
	# Выбор запоминается, только когда файл записан, — иначе повтор на следующем
	# проходе.
	if ! { echo "$via" > "$EGRESS_STATE.tmp" && mv -f "$EGRESS_STATE.tmp" "$EGRESS_STATE"; }; then
		echo "[portmap] WARNING: не удалось записать $EGRESS_STATE, выход остаётся прежним"
		return 0
	fi
	case $via in
		primary) echo "[portmap] выход: отдельный прокси ($EGRESS_PRIMARY)" ;;
		docker)  echo "[portmap] выход: прокси Docker Desktop ($EGRESS_FALLBACK)" ;;
	esac
	egress_via=$via
}

trap 'echo "[portmap] terminating"; [ -n "$egress_pid" ] && kill "$egress_pid" 2>/dev/null; exit 0' TERM INT

choose_egress
start_egress

# egress нужен и до появления мастера — следить за ним начинаем сразу.
echo "[portmap] waiting for shared ControlMaster socket..."
while ! compgen -G "$CTRL_GLOB" >/dev/null; do
	keep_egress
	choose_egress
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

# <порт>:<адрес>[:<порт цели>] -> аргумент для -R. Без порта цели номер на
# дальней стороне совпадает с номером здесь: одинаковые проще искать в логах.
#
# Адрес привязки задан явно, и это не косметика. Без него sshd вешает форвард на
# оба стека сразу, а успехом считает привязку хотя бы к одному: занят IPv4 —
# форвард встаёт только на IPv6, `ssh -O forward` возвращает ноль, и порт с виду
# есть. Обращения на 127.0.0.1 при этом молчат, а цикл больше не повторяет
# попытку — он же получил успех. С явным адресом занятый порт даёт честную
# ошибку, и следующая попытка проходит, когда порт освободится.
reverse_spec() {
	local port=${1%%:*} rest=${1#*:}
	local target=${rest%%:*} tport=${rest#*:}
	[ "$tport" = "$rest" ] && tport=$port
	echo "127.0.0.1:$port:$target:$tport"
}

# Опечатка в записи не должна молча выключать форвард.
checked=""
for r in $REVERSE; do
	if [[ "$r" =~ ^[0-9]+:[^:]+(:[0-9]+)?$ ]]; then
		checked+="$r "
	else
		echo "[portmap] WARNING: обратный форвард '$r' пропущен — формат <порт>:<адрес>[:<порт цели>]"
	fi
done
REVERSE=$checked

# Снять форварды, оставшиеся от прошлого экземпляра контейнера: мастер их переживает,
# и без очистки active[] после рестарта пуст, а forward на уже занятый порт падает —
# причём занят он собственным же осиротевшим форвардом, поэтому на хосте его не видно
# ни в lsof, ни в netstat (слушает sshd мастера, а не отдельный процесс).
#
# Вызывается при КАЖДОМ восстановлении соединения, а не однократно на старте: если
# мастера в момент запуска не было, единичная очистка молча пропускалась, и потом
# форварды не поднимались до тех пор, пока мастер сам не переподключится.
cleanup_stale() {
	master_alive || return 0
	local p r
	for p in $(desired_ports); do
		ssh -O cancel -L "127.0.0.1:$p:127.0.0.1:$p" bpi 2>/dev/null || true
	done
	for r in $REVERSE; do
		ssh -O cancel -R "$(reverse_spec "$r")" bpi 2>/dev/null || true
	done
}

declare -A active failed active_r failed_r_at
master_was_down=1

while true; do
	keep_egress
	choose_egress

	if ! master_alive; then
		echo "[portmap] master not reachable (мёртв или нет прав на сокет — проверь uid), waiting..."
		active=()
		failed=()
		active_r=()
		failed_r_at=()
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

	# обратные: та же логика, но список постоянный, снимать нечего.
	# Повтор каждые пять секунд и есть лечение занятого порта — недобитая
	# сессия на дальней стороне отпускает его сама, и следующая попытка проходит
	for r in $REVERSE; do
		[ -n "${active_r[$r]:-}" ] && continue
		if err=$(ssh -O forward -R "$(reverse_spec "$r")" bpi 2>&1); then
			echo "[portmap] +reverse ${r%%:*}"
			active_r[$r]=1
			unset 'failed_r_at[$r]'
		elif [ -z "${failed_r_at[$r]:-}" ] || (( SECONDS - failed_r_at[$r] >= FAIL_REPEAT )); then
			echo "[portmap] failed to reverse-forward ${r%%:*}: ${err:-причина неизвестна, ssh промолчал} (порт держит недобитая сессия — отпустит сама; держит дольше минуты — переоткрой мастер)"
			failed_r_at[$r]=$SECONDS
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
