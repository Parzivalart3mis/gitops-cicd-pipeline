#!/bin/sh
# entrypoint.sh — Runtime configuration for the frontend container.
#
# 1. BACKEND_UPSTREAM (e.g. http://backend:8000): when set, write an Nginx
#    snippet that reverse-proxies /backend/* to that address. In Kubernetes
#    this is the backend Service, reachable only from inside the cluster.
#    Proxying keeps browser traffic same-origin, so the UI works through the
#    Ingress host and through `kubectl port-forward` alike, with no CORS and
#    no cluster-internal hostnames in the browser.
#
# 2. BACKEND_URL: the base URL the browser's JavaScript calls. In Kubernetes
#    it is "/backend" (the proxy above). Running the container by itself,
#    point it at a published backend, e.g. http://localhost:8000.
#
# 3. FRONTEND_VERSION: shown in the UI.
#
# Values are injected at start-up rather than build time so one immutable
# image is promoted unchanged through dev → staging → prod.
#
# Any arguments replace the default command, so `docker run <image> nginx -t`
# validates the fully rendered configuration, proxy snippet included.

set -eu

BACKEND_URL="${BACKEND_URL:-http://localhost:8000}"
BACKEND_UPSTREAM="${BACKEND_UPSTREAM:-}"
FRONTEND_VERSION="${FRONTEND_VERSION:-unknown}"

HTML=/usr/share/nginx/html/index.html
SNIPPET=/etc/nginx/snippets/backend-proxy.conf

echo "[entrypoint] BACKEND_URL=${BACKEND_URL}"
echo "[entrypoint] BACKEND_UPSTREAM=${BACKEND_UPSTREAM:-<unset: no /backend proxy>}"
echo "[entrypoint] FRONTEND_VERSION=${FRONTEND_VERSION}"

if [ -n "${BACKEND_UPSTREAM}" ]; then
    # Only accept scheme://host[:port] so the value can't inject Nginx config.
    if ! printf '%s' "${BACKEND_UPSTREAM}" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]+)?/?$'; then
        echo "[entrypoint] ERROR: BACKEND_UPSTREAM must look like http://host:port" >&2
        exit 1
    fi
    upstream="${BACKEND_UPSTREAM%/}"
    # ^~ stops the static-asset regex location from capturing /backend/*.js etc.
    # The trailing slash on proxy_pass strips the /backend prefix.
    cat > "${SNIPPET}" <<EOF
location ^~ /backend/ {
    proxy_pass         ${upstream}/;
    proxy_http_version 1.1;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_connect_timeout 5s;
    proxy_read_timeout    30s;
}
EOF
else
    rm -f "${SNIPPET}"
fi

# Escape characters that are special in a sed replacement (\ | &).
sed_escape() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }

sed -i "s|__BACKEND_URL__|$(sed_escape "${BACKEND_URL}")|g"           "${HTML}"
sed -i "s|__FRONTEND_VERSION__|$(sed_escape "${FRONTEND_VERSION}")|g" "${HTML}"

if [ "$#" -eq 0 ]; then
    set -- nginx -g "daemon off;"
fi
exec "$@"
