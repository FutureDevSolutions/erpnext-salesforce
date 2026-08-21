#!/bin/bash
# Render the nginx config from the environment and hand over to nginx.
set -euo pipefail

: "${SITE_NAME:?SITE_NAME must be set}"

export BACKEND="${BACKEND:-backend:8000}"
export SOCKETIO="${SOCKETIO:-websocket:9000}"
export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"
export PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-120}"

# envsubst is given an explicit allow-list. With no arguments it would also
# expand nginx's own runtime variables ($uri, $host, $http_upgrade, ...) into
# empty strings and produce a config that silently misroutes every request.
envsubst '${SITE_NAME} ${BACKEND} ${SOCKETIO} ${CLIENT_MAX_BODY_SIZE} ${PROXY_READ_TIMEOUT}' \
	< /templates/nginx.conf.template \
	> /etc/nginx/conf.d/frappe.conf

echo "[nginx] serving ${SITE_NAME} -> backend ${BACKEND}, socketio ${SOCKETIO}" >&2

nginx -t
exec nginx -g 'daemon off;'
