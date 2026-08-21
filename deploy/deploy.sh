#!/usr/bin/env bash
# The pipeline. Run from anywhere:
#
#   deploy/deploy.sh                 # preflight -> build -> up
#   deploy/deploy.sh --skip-build    # preflight -> up
#   deploy/deploy.sh --no-provision  # fail instead of creating a database
#
# Step 1 guarantees a usable MariaDB, and may rewrite DB_HOST/DB_PORT in .env.
# Steps 2-3 read .env *after* that, so they always see the corrected values.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
ENV_FILE="${ENV_FILE:-$HERE/.env}"
IMAGE_TAG="${IMAGE_TAG:-erpnext-salesforce:latest}"

SKIP_BUILD=0
PREFLIGHT_ARGS=()

while [ $# -gt 0 ]; do
	case "$1" in
	--skip-build) SKIP_BUILD=1; shift ;;
	--no-provision) PREFLIGHT_ARGS+=(--no-provision); shift ;;
	--env-file) ENV_FILE="$2"; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

say() { echo; echo "=== $* ==="; }

[ -f "$ENV_FILE" ] || {
	echo "No env file at $ENV_FILE" >&2
	echo "Create one:  cp deploy/.env.example deploy/.env" >&2
	exit 1
}

# ---------------------------------------------------- 1. database preflight
say "1/3 database preflight"
# ${a[@]+...} guards against bash 3.2 treating an empty array as unbound.
"$HERE/preflight-db.sh" --env-file "$ENV_FILE" ${PREFLIGHT_ARGS[@]+"${PREFLIGHT_ARGS[@]}"}

# preflight-db.sh may have changed DB_HOST/DB_PORT, so re-read them here.
DB_HOST="$(grep -E '^[[:space:]]*DB_HOST=' "$ENV_FILE" | tail -1 | cut -d= -f2-)"

# If the preflight provisioned a database, the mariadb service has to stay in
# the compose invocation or the next `up` would tear it down again.
COMPOSE_FILES=(-f "$HERE/docker-compose.prod.yml")
if [ "$DB_HOST" = "mariadb" ]; then
	COMPOSE_FILES+=(-f "$HERE/docker-compose.mariadb.yml")
fi

compose() { docker compose "${COMPOSE_FILES[@]}" --env-file "$ENV_FILE" "$@"; }

# ------------------------------------------------------------- 2. build
if [ "$SKIP_BUILD" = "0" ]; then
	say "2/3 building $IMAGE_TAG"
	# Not piped: `docker build | tail` reports tail's exit status, and a failed
	# build would sail through as success.
	docker build -t "$IMAGE_TAG" "$ROOT"
else
	say "2/3 build skipped"
fi

# ------------------------------------------------------------- 3. up
say "3/3 starting the stack"
compose up -d

say "done"
compose ps
echo
echo "create-site runs migrations before the app containers start; follow it with:"
echo "  docker compose ${COMPOSE_FILES[*]} --env-file $ENV_FILE logs -f create-site backend"
