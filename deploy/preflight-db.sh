#!/usr/bin/env bash
# Preflight: guarantee the stack has a MariaDB it can actually authenticate to.
#
#   1. Probe DB_HOST:DB_PORT from inside Docker - the app containers' point of
#      view, not the host's.
#   2. Reachable and the credentials work  -> nothing to do.
#   3. Nothing listening                   -> provision one on DB_PORT.
#   4. Reachable but credentials rejected  -> something else owns that address.
#                                             Provision on the next free port and
#                                             rewrite DB_PORT in .env.
#
# Provisioned databases are the `mariadb` service in docker-compose.mariadb.yml,
# so DB_HOST is set to `mariadb`. It listens on DB_PORT internally AND publishes
# the same number on the host, so DB_HOST:DB_PORT means one thing everywhere.
#
# Usage: deploy/preflight-db.sh [--env-file deploy/.env] [--no-provision]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
NO_PROVISION=0
MARIADB_IMAGE="${MARIADB_IMAGE:-docker.io/mariadb:11.8}"

while [ $# -gt 0 ]; do
	case "$1" in
	--env-file) ENV_FILE="$2"; shift 2 ;;
	--no-provision) NO_PROVISION=1; shift ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

say()  { echo "[preflight-db] $*" >&2; }
die()  { echo "[preflight-db] ERROR: $*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE (copy deploy/.env.example)"

# --------------------------------------------------------------- load .env
# Parsed rather than sourced: sourcing executes the file, and a password
# containing $(...) or backticks would run as code.
load_env() {
	local line key val
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '' | '#'*) continue ;; esac
		[ "${line#*=}" = "$line" ] && continue
		key="${line%%=*}"
		val="${line#*=}"
		key="$(printf '%s' "$key" | tr -d '[:space:]')"
		# Strip one layer of matching quotes, if present.
		case "$val" in
		\"*\") val="${val#\"}"; val="${val%\"}" ;;
		\'*\') val="${val#\'}"; val="${val%\'}" ;;
		esac
		printf -v "$key" '%s' "$val"
		export "${key?}"
	done <"$ENV_FILE"
}
load_env

DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD must be set in $ENV_FILE}"

COMPOSE_PROD="$HERE/docker-compose.prod.yml"
COMPOSE_DB="$HERE/docker-compose.mariadb.yml"
compose() { docker compose -f "$COMPOSE_PROD" -f "$COMPOSE_DB" --env-file "$ENV_FILE" "$@"; }

# The compose network, so the probe sees exactly what a backend container would.
NETWORK="$(compose config 2>/dev/null | awk '/^networks:/{f=1} f&&/name:/{print $2; exit}')"
NETWORK="${NETWORK:-erpnext-prod_default}"

# ------------------------------------------------------------------- probe
# Returns: ok | auth | unreachable
probe() {
	local host="$1" port="$2" out rc net_args=()

	# A container cannot reach the host's loopback by that name.
	case "$host" in
	localhost | 127.0.0.1 | 0.0.0.0) host="host.docker.internal" ;;
	esac

	# Only attach to the compose network if it already exists; on a first run it
	# does not, and an external hostname is reachable from the default bridge.
	if docker network inspect "$NETWORK" >/dev/null 2>&1; then
		net_args=(--network "$NETWORK")
	fi

	set +e
	# ${a[@]+"${a[@]}"} rather than "${a[@]}": under `set -u`, bash 3.2 (which is
	# what /bin/bash is on macOS) treats an empty array expansion as unbound.
	out="$(docker run --rm ${net_args[@]+"${net_args[@]}"} \
		-e MYSQL_PWD="$DB_ROOT_PASSWORD" \
		"$MARIADB_IMAGE" \
		mariadb -h "$host" -P "$port" -u "$DB_ROOT_USER" \
		--connect-timeout=5 -e 'SELECT 1' 2>&1)"
	rc=$?
	set -e

	if [ $rc -eq 0 ]; then echo ok; return; fi
	# 1045 = access denied: the server answered, it just refused these creds.
	# 2002/2003 = could not connect at all.
	case "$out" in
	*"ERROR 1045"* | *"Access denied"*) echo auth; return ;;
	*"ERROR 2002"* | *"ERROR 2003"* | *"Can't connect"* | *"Unknown server host"*) echo unreachable; return ;;
	esac
	say "unrecognised probe failure, treating as unreachable:"
	say "  ${out//$'\n'/ }"
	echo unreachable
}

# Free if we can bind it on the host AND no container publishes it.
port_is_free() {
	local port="$1"
	python3 - "$port" <<'PY' || return 1
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
	! docker ps --format '{{.Ports}}' | grep -q ":${port}->"
}

next_free_port() {
	local port="$1" limit=$((${1} + 50))
	while [ "$port" -le "$limit" ]; do
		if port_is_free "$port" && [ "$(probe "127.0.0.1" "$port")" = "unreachable" ]; then
			echo "$port"; return 0
		fi
		port=$((port + 1))
	done
	die "no free port found in range ${1}-${limit}"
}

# Rewrite a KEY=value in .env in place, appending if the key is absent.
set_env_var() {
	local key="$1" val="$2" tmp
	cp -p "$ENV_FILE" "${ENV_FILE}.bak"
	tmp="$(mktemp)"
	if grep -qE "^[[:space:]]*${key}=" "$ENV_FILE"; then
		# Value substituted via awk, not sed, so characters that are special to
		# a sed replacement (&, /, \) survive a password unharmed.
		KEY="$key" VAL="$val" awk '
			BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
			$0 ~ "^[[:space:]]*" k "=" { print k "=" v; next }
			{ print }
		' "$ENV_FILE" >"$tmp"
	else
		cat "$ENV_FILE" >"$tmp"
		printf '%s=%s\n' "$key" "$val" >>"$tmp"
	fi
	cat "$tmp" >"$ENV_FILE"
	rm -f "$tmp"
	say "set ${key}=${val} in ${ENV_FILE} (backup: ${ENV_FILE}.bak)"
}

provision() {
	local port="$1"
	[ "$NO_PROVISION" = "1" ] && die "no usable database and --no-provision was given"

	say "provisioning MariaDB (${MARIADB_IMAGE}) on port ${port}"
	DB_PORT="$port" compose up -d mariadb

	say "waiting for it to become healthy ..."
	local cid attempt=0
	cid="$(DB_PORT="$port" compose ps -q mariadb)"
	[ -n "$cid" ] || die "mariadb container did not start"
	until [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" = "healthy" ]; do
		attempt=$((attempt + 1))
		[ "$attempt" -ge 120 ] && die "mariadb did not become healthy; see: docker logs $cid"
		sleep 2
	done
	say "MariaDB is healthy"
}

# -------------------------------------------------------------------- main
if [ -z "$DB_HOST" ]; then
	say "DB_HOST is empty - will provision a local MariaDB"
	result=unreachable
else
	say "probing ${DB_HOST}:${DB_PORT} as ${DB_ROOT_USER} ..."
	result="$(probe "$DB_HOST" "$DB_PORT")"
fi

case "$result" in
ok)
	say "OK: ${DB_HOST}:${DB_PORT} is reachable and the credentials work"
	exit 0
	;;

unreachable)
	say "nothing is serving MariaDB at ${DB_HOST:-<unset>}:${DB_PORT}"
	# Warn loudly before repointing what looks like a deliberate external target.
	case "$DB_HOST" in
	'' | mariadb | localhost | 127.0.0.1 | host.docker.internal) ;;
	*)
		say "WARNING: DB_HOST=${DB_HOST} looks like an external database."
		say "WARNING: it is unreachable, so DB_HOST will be repointed at a local"
		say "WARNING: container. Re-run with --no-provision to fail instead."
		;;
	esac

	port="$DB_PORT"
	if ! port_is_free "$port"; then
		say "host port ${port} is occupied by something that is not MariaDB"
		port="$(next_free_port $((DB_PORT + 1)))"
		set_env_var DB_PORT "$port"
	fi
	set_env_var DB_HOST mariadb
	provision "$port"
	;;

auth)
	say "a database answered at ${DB_HOST}:${DB_PORT} but rejected ${DB_ROOT_USER}"

	# If that database is our own mariadb service, a second instance solves
	# nothing: MariaDB fixes the root password when the data directory is first
	# initialised, so the volume - not the port - is what is rejecting us.
	if [ -n "$(compose ps -q mariadb 2>/dev/null || true)" ]; then
		say "that database is this stack's own 'mariadb' service."
		die "$(cat <<-MSG

		DB_ROOT_PASSWORD in $ENV_FILE does not match the password its data
		volume was initialised with. Starting another instance would not help.
		Either:
		  - restore the original DB_ROOT_PASSWORD in $ENV_FILE, or
		  - change the password:
		      docker compose -f $COMPOSE_PROD -f $COMPOSE_DB --env-file $ENV_FILE \\
		        exec mariadb mariadb -u root -p -e \\
		        "ALTER USER 'root'@'%' IDENTIFIED BY '<new>'"
		  - or discard the data and start over (DESTROYS ALL DATA):
		      docker volume rm ${DB_VOLUME_NAME:-erpnext-mariadb-data}
		MSG
		)"
	fi

	# Otherwise it is a foreign database. Never touch it - it could be another
	# application's data. Stand up our own alongside it, on its own port and its
	# own volume.
	say "leaving it alone and provisioning a separate instance"
	port="$(next_free_port $((DB_PORT + 1)))"
	set_env_var DB_PORT "$port"
	set_env_var DB_HOST mariadb
	set_env_var DB_VOLUME_NAME "erpnext-mariadb-data-${port}"
	export DB_VOLUME_NAME="erpnext-mariadb-data-${port}"
	provision "$port"
	;;
esac

# ------------------------------------------------------------------ verify
# Provisioning that "succeeded" but cannot be authenticated to is the failure
# mode this whole script exists to prevent, so prove it before returning 0.
load_env
say "verifying ${DB_HOST}:${DB_PORT} ..."
final="$(probe "$DB_HOST" "$DB_PORT")"
[ "$final" = "ok" ] || die "provisioned database still not usable (probe said: $final)"
say "OK: ${DB_HOST}:${DB_PORT} is reachable and the credentials work"
