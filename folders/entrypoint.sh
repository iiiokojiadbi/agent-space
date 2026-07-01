#!/bin/sh
set -e

# Ждём не просто наличие сокета, а ЖИВОЙ мастер: stale-сокет от прошлой сессии
# существует как файл, но коннект через него падает — раньше это давало рестарт-луп.
wait_live_master() {
	echo "[folders] waiting for live ControlMaster (мёртв или нет прав на сокет — проверь uid)..."
	while true; do
		if ls /run/ssh-control/cm-*.sock >/dev/null 2>&1 && \
		   ssh -O check bpi >/dev/null 2>&1; then
			echo "[folders] ControlMaster live"
			return 0
		fi
		sleep 2
	done
}

mutagen daemon start
cd /workspace

while true; do
	wait_live_master

	# всегда сносим возможные висящие/старые сессии перед стартом — иначе повторный
	# project start после восстановления мастера плодит дубли sync-сессий
	mutagen project terminate 2>/dev/null || true
	rm -f mutagen.yml.lock

	if ! mutagen project start; then
		echo "[folders] project start failed, retrying"
		sleep 5
		continue
	fi

	# monitor держит контейнер живым, пока мастер жив; вернётся сюда, если мастер умрёт
	mutagen sync monitor || true
	echo "[folders] sync monitor exited (master gone?), re-waiting for master"
	sleep 2
done
