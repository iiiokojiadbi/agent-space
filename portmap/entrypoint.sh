#!/bin/bash
set -e

MAP=/run/services.map
CTRL_GLOB='/run/ssh-control/cm-*.sock'

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

# снять форварды, оставшиеся от прошлого экземпляра контейнера (мастер их переживает) —
# иначе active[] после рестарта пуст, forward на уже занятый порт спамит ошибками, а
# снять его потом некому (утечка)
if ssh -O check bpi >/dev/null 2>&1; then
	for p in $(desired_ports); do
		ssh -O cancel -L "127.0.0.1:$p:127.0.0.1:$p" bpi 2>/dev/null || true
	done
fi

declare -A active failed

while true; do
	if ! ssh -O check bpi >/dev/null 2>&1; then
		echo "[portmap] master not reachable (мёртв или нет прав на сокет — проверь uid), waiting..."
		active=()
		failed=()
		sleep 5
		continue
	fi

	declare -A want=()
	while read -r p; do
		[ -n "$p" ] && want[$p]=1
	done < <(desired_ports)

	# добавить новые
	for p in "${!want[@]}"; do
		[ -n "${active[$p]:-}" ] && continue
		if ssh -O forward -L "127.0.0.1:$p:127.0.0.1:$p" bpi 2>/dev/null; then
			echo "[portmap] +forward $p"
			active[$p]=1
			unset 'failed[$p]'
		elif [ -z "${failed[$p]:-}" ]; then
			# логируем один раз, а не каждые 5с
			echo "[portmap] failed to forward $p (порт занят на host loopback?)"
			failed[$p]=1
		fi
	done

	# снять исчезнувшие
	for p in "${!active[@]}"; do
		if [ -z "${want[$p]:-}" ]; then
			if ssh -O cancel -L "127.0.0.1:$p:127.0.0.1:$p" bpi 2>/dev/null; then
				echo "[portmap] -forward $p"
				unset 'active[$p]'
			else
				echo "[portmap] failed to cancel $p, keep tracking"
			fi
		fi
	done

	sleep 5
done
