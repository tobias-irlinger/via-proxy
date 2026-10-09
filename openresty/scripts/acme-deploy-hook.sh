#!/bin/bash
# certbot deploy hook (registered by setup_acme.sh): copies the new
# certificate to the directory OpenResty reads and reloads OpenResty.
# A reload keeps running connections and the usage-limit counters.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LINEAGE="${RENEWED_LINEAGE:?only to be run by certbot}"
CERT_DIR="${VIA_CERT_DIR:-${PROJECT_DIR}/certs}"
ENV_FILE="${VIA_ENV_FILE:-${PROJECT_DIR}/.env}"

mkdir -p "${CERT_DIR}"
# copy next to the target, then rename: OpenResty never sees half a file
install -m 600 "${LINEAGE}/privkey.pem" "${CERT_DIR}/privkey.pem.new"
install -m 644 "${LINEAGE}/fullchain.pem" "${CERT_DIR}/fullchain.pem.new"
mv -f "${CERT_DIR}/privkey.pem.new" "${CERT_DIR}/privkey.pem"
mv -f "${CERT_DIR}/fullchain.pem.new" "${CERT_DIR}/fullchain.pem"

compose=(docker compose --project-directory "${PROJECT_DIR}"
         --env-file "${ENV_FILE}" -f "${PROJECT_DIR}/docker-compose.yml")
if [ -n "$("${compose[@]}" ps --status running -q openresty 2>/dev/null)" ]; then
    # nginx prints its "signal process started" notice on stderr
    "${compose[@]}" exec -T openresty openresty -s reload 2>&1
    echo "via-proxy: certificate updated, OpenResty reloaded"
else
    echo "via-proxy: certificate updated, OpenResty not running"
fi
