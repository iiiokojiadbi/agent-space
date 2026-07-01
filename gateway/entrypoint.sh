#!/bin/bash
set -e

MAP_SRC=/etc/caddy/services.map
SNIPPET=/etc/caddy/services_map_entries.caddy
TEMPLATE=/etc/caddy/Caddyfile.template
CADDYFILE=/etc/caddy/Caddyfile

gen_snippet() {
	: > "$SNIPPET"
	[ -f "$MAP_SRC" ] || return 0
	# awk дедуплицирует имена (берёт первое) и предупреждает о дублях —
	# иначе Caddy map молча взял бы последнее совпадение
	awk 'NF && $1 !~ /^#/ {
		if (seen[$1]++) { print "[gateway] WARNING: duplicate service name: " $1 > "/dev/stderr"; next }
		if ($1 != "" && $2 != "") print $1, $2
	}' "$MAP_SRC" >> "$SNIPPET"
}

if [ -d "$MAP_SRC" ]; then
	echo "[gateway] WARNING: $MAP_SRC is a directory — забыл создать services.map из services.map.example?"
fi

cp "$TEMPLATE" "$CADDYFILE"
gen_snippet

caddy run --config "$CADDYFILE" --adapter caddyfile &
CADDY_PID=$!
# graceful shutdown: пробросить SIGTERM в caddy, иначе docker stop ждёт grace-period и бьёт SIGKILL
trap 'echo "[gateway] stopping caddy"; kill -TERM "$CADDY_PID" 2>/dev/null; wait "$CADDY_PID"; exit 0' TERM INT

last=$(md5sum "$MAP_SRC" 2>/dev/null | cut -d' ' -f1)
while kill -0 "$CADDY_PID" 2>/dev/null; do
	sleep 5
	cur=$(md5sum "$MAP_SRC" 2>/dev/null | cut -d' ' -f1)
	if [ "$cur" != "$last" ]; then
		echo "[gateway] services.map changed, regenerating + reloading"
		gen_snippet
		if caddy reload --config "$CADDYFILE" --adapter caddyfile; then
			last="$cur"
		else
			echo "[gateway] reload failed, will retry on next change"
		fi
	fi
done

wait "$CADDY_PID"
