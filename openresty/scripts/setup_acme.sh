#!/bin/bash
# ============================================================
# ACME certificate setup for the proxy (wildcard *.PROXY_DOMAIN)
# Same approach as HM_template/scripts/setup_acme.sh: certbot with the
# internal HM ACME server and EAB credentials. Differences:
#   - wildcard certificate (PROXY_DOMAIN and *.PROXY_DOMAIN)
#   - challenge via DNS (RFC 2136) or webroot served by OpenResty,
#     no standalone mode (port 80 belongs to OpenResty)
#   - settings come from .env, renewal via certbot's timer and
#     scripts/acme-deploy-hook.sh (copies the files, reloads OpenResty)
# ============================================================
set -euo pipefail

if [ "${DEBUG:-0}" = "1" ]; then set -x; fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${VIA_ENV_FILE:-${PROJECT_DIR}/.env}"
CERTBOT="${CERTBOT:-certbot}"
APT_SUDO=""
[ "$(id -u)" = 0 ] || APT_SUDO="sudo"

if [ ! -f "${ENV_FILE}" ]; then
    echo "FEHLER: ${ENV_FILE} nicht gefunden!"
    exit 1
fi

# KEY=value from the env file (no shell evaluation, values may contain spaces)
env_get() {
    local line
    line=$(grep -E "^$1=" "${ENV_FILE}" | tail -n1 || true)
    line=${line#*=}
    line=${line%\"}; line=${line#\"}
    echo "${line}"
}

DOMAIN=$(env_get PROXY_DOMAIN)
ACME_SERVER=$(env_get ACME_SERVER)
ACME_SERVER=${ACME_SERVER:-https://acme.hm.edu/acme/acme/directory}
EAB_KID=$(env_get ACME_EAB_KID)
EAB_HMAC_KEY=$(env_get ACME_EAB_HMAC_KEY)
EMAIL=$(env_get ACME_EMAIL)
EMAIL=${EMAIL:-noreply@notused.local}
CHALLENGE=$(env_get ACME_CHALLENGE)
CHALLENGE=${CHALLENGE:-dns-rfc2136}
CERT_DIR=$(env_get VIA_CERT_DIR)
CERT_DIR=${CERT_DIR:-./certs}
WEBROOT=$(env_get VIA_ACME_WEBROOT)
WEBROOT=${WEBROOT:-./acme-webroot}
# certbot state; only tests change this
CERTBOT_DIR=$(env_get ACME_CERTBOT_DIR)
CERTBOT_DIR=${CERTBOT_DIR:-/etc/letsencrypt}

# certbot needs root only for the system-wide /etc/letsencrypt
SUDO=""
if [ "$(id -u)" != 0 ]; then
    mkdir -p "${CERTBOT_DIR}" 2>/dev/null || true
    [ -w "${CERTBOT_DIR}" ] || SUDO="sudo"
fi

abspath() { [[ "$1" = /* ]] && echo "$1" || echo "${PROJECT_DIR}/${1#./}"; }
CERT_DIR=$(abspath "${CERT_DIR}")
WEBROOT=$(abspath "${WEBROOT}")
ENV_FILE=$(abspath "${ENV_FILE}")

# Validierung
if [ -z "${DOMAIN}" ] || [ "${DOMAIN}" = "proxy.bib.example.org" ]; then
    echo "FEHLER: PROXY_DOMAIN in ${ENV_FILE} nicht gesetzt!"
    exit 1
fi
if [ -z "${EAB_KID}" ] || [ "${EAB_KID}" = "CHANGE-ME" ]; then
    echo "FEHLER: ACME_EAB_KID in ${ENV_FILE} nicht gesetzt!"
    exit 1
fi
if [ -z "${EAB_HMAC_KEY}" ] || [ "${EAB_HMAC_KEY}" = "CHANGE-ME" ]; then
    echo "FEHLER: ACME_EAB_HMAC_KEY in ${ENV_FILE} nicht gesetzt!"
    exit 1
fi

echo "============================================"
echo "  ACME Setup"
echo "  Domains:     ${DOMAIN}, *.${DOMAIN}"
echo "  ACME-Server: ${ACME_SERVER}"
echo "  Challenge:   ${CHALLENGE}"
echo "  Zertifikate: ${CERT_DIR}"
echo "============================================"

# certbot installieren
need_pkg=""
command -v "${CERTBOT}" &>/dev/null || need_pkg="certbot"
certbot_dirs=(--config-dir "${CERTBOT_DIR}" --work-dir "${CERTBOT_DIR}/work"
              --logs-dir "${CERTBOT_DIR}/logs")
if [ "${CHALLENGE}" = "dns-rfc2136" ] &&
        ! ${SUDO} "${CERTBOT}" plugins "${certbot_dirs[@]}" 2>/dev/null | grep -q dns-rfc2136; then
    need_pkg="${need_pkg} python3-certbot-dns-rfc2136"
fi
if [ -n "${need_pkg}" ]; then
    # shellcheck disable=SC2086
    ${APT_SUDO} apt-get update -qq && ${APT_SUDO} apt-get install -y ${need_pkg}
fi

challenge_args=()
case "${CHALLENGE}" in
    dns-rfc2136)
        # TXT records via dynamic DNS update (TSIG key from the DNS team)
        creds="${CERTBOT_DIR}/via-proxy-rfc2136.ini"
        for key in ACME_RFC2136_SERVER ACME_RFC2136_NAME ACME_RFC2136_SECRET; do
            if [ -z "$(env_get "${key}")" ]; then
                echo "FEHLER: ${key} in ${ENV_FILE} nicht gesetzt (für ACME_CHALLENGE=dns-rfc2136)!"
                exit 1
            fi
        done
        port=$(env_get ACME_RFC2136_PORT)
        algorithm=$(env_get ACME_RFC2136_ALGORITHM)
        ${SUDO} mkdir -p "${CERTBOT_DIR}"
        ${SUDO} install -m 600 /dev/null "${creds}"
        ${SUDO} tee "${creds}" > /dev/null <<EOF
dns_rfc2136_server = $(env_get ACME_RFC2136_SERVER)
dns_rfc2136_port = ${port:-53}
dns_rfc2136_name = $(env_get ACME_RFC2136_NAME)
dns_rfc2136_secret = $(env_get ACME_RFC2136_SECRET)
dns_rfc2136_algorithm = ${algorithm:-HMAC-SHA512}
EOF
        propagation=$(env_get ACME_RFC2136_PROPAGATION)
        challenge_args=(--dns-rfc2136 --dns-rfc2136-credentials "${creds}"
                        --dns-rfc2136-propagation-seconds "${propagation:-30}")
        ;;
    webroot)
        # Only for CAs that do not demand a DNS challenge for the wildcard
        # (pre-validated domains). OpenResty serves the files on port 80.
        mkdir -p "${WEBROOT}"
        challenge_args=(--webroot -w "${WEBROOT}")
        ;;
    *)
        echo "FEHLER: ACME_CHALLENGE muss dns-rfc2136 oder webroot sein!"
        exit 1
        ;;
esac

mkdir -p "${CERT_DIR}"

# Zertifikat ausstellen; der Deploy-Hook läuft danach und bei jeder Erneuerung
${SUDO} "${CERTBOT}" certonly \
    --non-interactive \
    --agree-tos \
    --email "${EMAIL}" \
    --server "${ACME_SERVER}" \
    --key-type ecdsa \
    --eab-kid "${EAB_KID}" \
    --eab-hmac-key "${EAB_HMAC_KEY}" \
    --issuance-timeout 300 \
    "${certbot_dirs[@]}" \
    --cert-name via-proxy \
    "${challenge_args[@]}" \
    --deploy-hook "env VIA_CERT_DIR='${CERT_DIR}' VIA_ENV_FILE='${ENV_FILE}' '${PROJECT_DIR}/scripts/acme-deploy-hook.sh'" \
    --domains "${DOMAIN},*.${DOMAIN}"

echo ""
if [ "${CERTBOT_DIR}" = "/etc/letsencrypt" ]; then
    if systemctl is-enabled certbot.timer &>/dev/null; then
        echo "  Erneuerung: automatisch (certbot.timer), Test: sudo certbot renew --dry-run"
    else
        echo "  WARNUNG: certbot.timer ist nicht aktiv, Erneuerung per Cron einrichten:"
        echo "  0 3 * * * certbot renew --quiet"
    fi
fi
echo "  → https://login.${DOMAIN}/"
