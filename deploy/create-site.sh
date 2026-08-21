#!/bin/bash
# One-shot job: create the site on first boot, migrate it on every boot after.
#
# Runs to completion and exits; the long-lived services wait on it via
# `depends_on: condition: service_completed_successfully`. Keeping this out of
# the app containers avoids several of them racing to create the same site.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
cd "$BENCH"

log() { echo "[create-site] $*" >&2; }

: "${SITE_NAME:?SITE_NAME must be set (e.g. erp.example.com)}"

if [ -f "sites/${SITE_NAME}/site_config.json" ]; then
	log "site ${SITE_NAME} exists - running migrate"
	bench --site "$SITE_NAME" migrate
	# Assets are rebuilt into every image, so a deploy can leave the cached
	# asset manifest stale. Cheap to clear, expensive to debug.
	bench --site "$SITE_NAME" clear-cache

	# Report, but do not change it: an operator may have disabled the scheduler
	# deliberately for maintenance, and a deploy should not silently undo that.
	if bench --site "$SITE_NAME" doctor 2>&1 | grep -q "Scheduler disabled"; then
		log "WARNING: the scheduler is DISABLED for ${SITE_NAME}."
		log "WARNING: no scheduled job will run - no recurring invoices, auto-emails"
		log "WARNING: or scheduled reports. Enable it with:"
		log "WARNING:   bench --site ${SITE_NAME} enable-scheduler"
	fi

	log "migrate complete"
	exit 0
fi

: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD must be set to create a site}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set to create a site}"

log "creating site ${SITE_NAME}"

# --mariadb-user-host-login-scope=% grants the generated site user access from
# any host. Required whenever the database is not on localhost, which is always
# true with a managed instance.
bench new-site "$SITE_NAME" \
	--db-root-username "${DB_ROOT_USER:-root}" \
	--db-root-password "$DB_ROOT_PASSWORD" \
	--admin-password "$ADMIN_PASSWORD" \
	--mariadb-user-host-login-scope='%' \
	--install-app erpnext \
	--set-default

# `bench new-site` leaves the scheduler DISABLED. The scheduler container will
# happily run against a site whose scheduler is off and log nothing unusual, so
# without this every scheduled job - recurring invoices, auto-emails, scheduled
# reports, cleanup - silently never runs.
log "enabling the scheduler"
bench --site "$SITE_NAME" enable-scheduler

log "site ${SITE_NAME} created and erpnext installed"
log "log in as Administrator with the password from ADMIN_PASSWORD"
