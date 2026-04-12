#!/bin/sh
# entrypoint.sh — Runtime configuration injection for the frontend container.
#
# At container start, replace the __BACKEND_URL__ placeholder in index.html
# with the value of the BACKEND_URL environment variable. This allows the
# same Docker image to target different backend URLs in each environment
# without a rebuild.
#
# Why not bake the URL at build time?
# Baking URLs means building a separate image per environment, which defeats
# the purpose of a single immutable artefact promoted through environments.

set -eu

BACKEND_URL="${BACKEND_URL:-http://localhost:8000}"
FRONTEND_VERSION="${FRONTEND_VERSION:-unknown}"

echo "[entrypoint] BACKEND_URL=${BACKEND_URL}"
echo "[entrypoint] FRONTEND_VERSION=${FRONTEND_VERSION}"

# Replace placeholders in the served index.html (Nginx serves from /usr/share/nginx/html)
sed -i "s|__BACKEND_URL__|${BACKEND_URL}|g"         /usr/share/nginx/html/index.html
sed -i "s|__FRONTEND_VERSION__|${FRONTEND_VERSION}|g" /usr/share/nginx/html/index.html

# Hand off to Nginx
exec nginx -g "daemon off;"
