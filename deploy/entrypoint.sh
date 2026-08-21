#!/bin/bash
# Shared entrypoint for every role of the erpnext image.
#
#   1. link the image-baked assets into the (empty) sites volume
#   2. render sites/common_site_config.json from the environment
#   3. wait for the database and redis to accept connections
#   4. exec the requested role
#
# Roles: gunicorn | websocket | worker | scheduler | nginx | <any command>
set -euo pipefail

BENCH=/home/frappe/frappe-bench
cd "$BENCH"

log() { echo "[entrypoint] $*" >&2; }

# --------------------------------------------------------------- 1. assets
# sites/ is a volume and starts empty, so the assets built into the image at
# $BENCH/assets have to be linked in. A symlink rather than a copy, so that
# deploying a new image serves the new assets without touching the volume.
if [ -d "$BENCH/assets" ] && [ ! -d "$BENCH/sites/assets" ]; then
	ln -sfn ../assets "$BENCH/sites/assets"
	log "linked sites/assets -> ../assets"
fi

mkdir -p "$BENCH/logs"

# --------------------------------------------------------------- 2. config
# Every key is optional here except db_host and the redis URLs; anything unset
# in the environment is left as-is so a value already written into the volume
# (or set by `bench set-config`) survives a restart.
python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path("/home/frappe/frappe-bench/sites/common_site_config.json")
try:
	cfg = json.loads(path.read_text() or "{}")
except (FileNotFoundError, json.JSONDecodeError):
	cfg = {}


def from_env(key, env, cast=str):
	value = os.environ.get(env)
	if value not in (None, ""):
		cfg[key] = cast(value)


def as_bool(value):
	return str(value).strip().lower() in ("1", "true", "yes", "on")


from_env("db_host", "DB_HOST")
from_env("db_port", "DB_PORT", int)

from_env("redis_cache", "REDIS_CACHE")
from_env("redis_queue", "REDIS_QUEUE")
from_env("redis_socketio", "REDIS_SOCKETIO")
# Frappe still reads redis_socketio in places; default it to the queue instance
# rather than the cache, because cache eviction would drop pub/sub state.
if "redis_socketio" not in cfg and "redis_queue" in cfg:
	cfg["redis_socketio"] = cfg["redis_queue"]

from_env("socketio_port", "SOCKETIO_PORT", int)

# Outgoing mail. Frappe prefers the Email Account doctype, but these site-config
# keys act as the fallback used before any Email Account exists - which is what
# makes password-reset and the setup wizard's invites work on a fresh deploy.
from_env("mail_server", "MAIL_SERVER")
from_env("mail_port", "MAIL_PORT", int)
from_env("mail_login", "MAIL_LOGIN")
from_env("mail_password", "MAIL_PASSWORD")
from_env("auto_email_id", "MAIL_FROM")
from_env("use_tls", "MAIL_USE_TLS", as_bool)

# Must be stable across containers and deploys: Frappe encrypts stored
# credentials with it, and a changed key makes them undecryptable.
from_env("encryption_key", "ENCRYPTION_KEY")

# Production hardening.
cfg.setdefault("developer_mode", 0)
from_env("maintenance_mode", "MAINTENANCE_MODE", int)
cfg["serve_default_site"] = True

path.write_text(json.dumps(cfg, indent=1, sort_keys=True))
print(f"[entrypoint] wrote {path} ({len(cfg)} keys)")
PY

# ---------------------------------------------------------------- 3. waits
# Managed database and redis endpoints come up independently of this container,
# so block until they answer rather than crash-looping on first connect.
wait_for() {
	local target="$1" label="$2" attempt=0
	local host="${target%:*}" port="${target##*:}"
	# No colon in the target means we could not parse a port; skip rather than
	# block forever. Written as an `if` because `[ x ] && return` under `set -e`
	# is the classic errexit footgun.
	if [ "$host" = "$port" ]; then
		log "skipping wait for $label: cannot parse host:port from '$target'"
		return 0
	fi

	until python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(3)
try:
    s.connect(('$host', int('$port')))
except OSError:
    sys.exit(1)
finally:
    s.close()
" 2>/dev/null; do
		attempt=$((attempt + 1))
		if [ "$attempt" -ge "${WAIT_RETRIES:-60}" ]; then
			log "ERROR: $label ($target) unreachable after $attempt attempts"
			exit 1
		fi
		if [ $((attempt % 5)) -eq 1 ]; then
			log "waiting for $label at $target ..."
		fi
		sleep 2
	done
	log "$label is up ($target)"
}

# Strip the scheme/db-index off a redis:// URL to get host:port.
redis_target() {
	echo "$1" | sed -E 's#^redis(s)?://##; s#^[^@]*@##; s#/.*$##'
}

if [ "${SKIP_WAITS:-0}" != "1" ]; then
	if [ -n "${DB_HOST:-}" ]; then
		wait_for "${DB_HOST}:${DB_PORT:-3306}" "database"
	fi
	if [ -n "${REDIS_CACHE:-}" ]; then
		wait_for "$(redis_target "$REDIS_CACHE")" "redis-cache"
	fi
	if [ -n "${REDIS_QUEUE:-}" ]; then
		wait_for "$(redis_target "$REDIS_QUEUE")" "redis-queue"
	fi
fi

# ---------------------------------------------------------------- 4. roles
role="${1:-gunicorn}"
shift || true

case "$role" in
gunicorn)
	# gthread, not gevent: Frappe's own production config uses threads, and the
	# database driver is not monkeypatch-safe.
	log "starting gunicorn (${GUNICORN_WORKERS:-2} workers x ${GUNICORN_THREADS:-4} threads)"
	exec "$BENCH/env/bin/gunicorn" \
		--chdir="$BENCH/sites" \
		--bind="0.0.0.0:${WEB_PORT:-8000}" \
		--workers="${GUNICORN_WORKERS:-2}" \
		--threads="${GUNICORN_THREADS:-4}" \
		--worker-class=gthread \
		--worker-tmp-dir=/dev/shm \
		--timeout="${GUNICORN_TIMEOUT:-120}" \
		--preload \
		frappe.app:application
	;;
websocket)
	log "starting realtime server on ${SOCKETIO_PORT:-9000}"
	exec node "$BENCH/apps/frappe/socketio.js"
	;;
worker)
	# --queue is a comma-separated list; omitting it consumes every queue.
	log "starting worker (queues: ${WORKER_QUEUES:-all})"
	if [ -n "${WORKER_QUEUES:-}" ]; then
		exec bench worker --queue "$WORKER_QUEUES"
	fi
	exec bench worker
	;;
scheduler)
	log "starting scheduler"
	exec bench schedule
	;;
nginx)
	exec /usr/local/bin/nginx-entrypoint.sh
	;;
*)
	# Anything else runs verbatim: `bench --site x migrate`, `bash`, etc.
	exec "$role" "$@"
	;;
esac
