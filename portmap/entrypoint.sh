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
# Формат: <порт>:<адрес назначения на этой машине>
REVERSE=${REVERSE_FORWARDS:-"2375:127.0.0.1 8089:host.docker.internal"}

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

# <порт>:<цель> -> аргумент для -R, в котором номер на дальней стороне совпадает
# с номером здесь: разводить их незачем, а одинаковые проще искать в логах
reverse_spec() {
	local port=${1%%:*} target=${1##*:}
	echo "$port:$target:$port"
}

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

declare -A active failed active_r failed_r
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

	# обратные: та же логика, но список постоянный, снимать нечего.
	# Повтор каждые пять секунд и есть лечение занятого порта — недобитая
	# сессия на дальней стороне отпускает его сама, и следующая попытка проходит
	for r in $REVERSE; do
		[ -n "${active_r[$r]:-}" ] && continue
		if err=$(ssh -O forward -R "$(reverse_spec "$r")" bpi 2>&1); then
			echo "[portmap] +reverse ${r%%:*}"
			active_r[$r]=1
			unset 'failed_r[$r]'
		elif [ -z "${failed_r[$r]:-}" ]; then
			echo "[portmap] failed to reverse-forward ${r%%:*}: ${err:-причина неизвестна, ssh промолчал}"
			failed_r[$r]=1
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
