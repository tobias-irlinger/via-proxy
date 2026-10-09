#!/bin/bash
# ACME test: scripts/setup_acme.sh against Pebble (Let's Encrypt's test CA)
# with EAB and a wildcard certificate via DNS-01 (RFC 2136 update with TSIG
# to a BIND server), then a forced renewal. Checks that the deploy hook
# installs the certificate and OpenResty serves it.
#   tests/acme.sh                 needs certbot (CERTBOT=/path/to/certbot)
#   KEEP=1 tests/acme.sh          leave the stack running afterwards
set -u
cd "$(dirname "$0")/.." || exit 1

PEBBLE_IMAGE=ghcr.io/letsencrypt/pebble:2.8.0
# Docker Hub via Google's mirror (avoids anonymous pull limits)
BIND_IMAGE=mirror.gcr.io/internetsystemsconsortium/bind9:9.20
CERTBOT=${CERTBOT:-certbot}
work=$(mktemp -d)
env_file=$work/acme.env

compose() {
    docker compose --env-file "$env_file" \
        -f docker-compose.yml -f tests/docker-compose.test.yml "$@"
}
cleanup() {
    if [ "${KEEP:-}" != 1 ]; then
        compose down -v >/dev/null 2>&1
        docker rm -f via-pebble via-bind >/dev/null 2>&1
    fi
    rm -rf "$work"
}
trap cleanup EXIT

fail=0 total=0
check() {   # check <description> <command...>
    total=$((total + 1))
    local desc=$1; shift
    if "$@"; then echo "ok   $desc"; else echo "FAIL $desc"; fail=$((fail + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1"; }

# Pebble: EAB required, challenges always valid (like a CA with
# pre-validated domains). Its bundled TLS certificate lacks extensions that
# Python 3.13 requires, so the ACME endpoint gets one from a throwaway CA.
mkdir -p "$work/pebble"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=via-proxy test CA" -keyout "$work/pebble/ca.key" -out "$work/pebble/ca.pem" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=localhost" \
    -keyout "$work/pebble/key.pem" -out "$work/pebble/req.csr" 2>/dev/null
openssl x509 -req -in "$work/pebble/req.csr" -CA "$work/pebble/ca.pem" -CAkey "$work/pebble/ca.key" \
    -days 1 -out "$work/pebble/cert.pem" -extfile <(printf '%s\n' \
    "subjectAltName=DNS:localhost" "authorityKeyIdentifier=keyid" \
    "extendedKeyUsage=serverAuth" "keyUsage=critical,digitalSignature") 2>/dev/null
cat > "$work/pebble/config.json" <<JSON
{"pebble": {
  "listenAddress": "0.0.0.0:14000", "managementListenAddress": "0.0.0.0:15000",
  "certificate": "/pebble/cert.pem", "privateKey": "/pebble/key.pem",
  "httpPort": 5002, "tlsPort": 5001, "ocspResponderURL": "",
  "externalAccountBindingRequired": true,
  "externalAccountMACKeys": {"kid-1": "zWNDZM6eQGHWpSRTPal5eIUYFTu7EajVIoguysqZ9wG44nMEtx3MUAsUDkMTQ12W"}
}}
JSON
chmod -R a+r "$work/pebble"
docker rm -f via-pebble >/dev/null 2>&1
docker run -d --name via-pebble -p 14000:14000 -v "$work/pebble:/pebble:ro" \
    -e PEBBLE_VA_ALWAYS_VALID=1 -e PEBBLE_VA_NOSLEEP=1 \
    "$PEBBLE_IMAGE" -config /pebble/config.json >/dev/null

# BIND: authoritative for proxy.test, TXT updates allowed with a TSIG key
tsig=$(openssl rand -base64 64 | tr -d '\n')
mkdir -p "$work/bind"
cat > "$work/bind/named.conf" <<CONF
key "acme" { algorithm hmac-sha512; secret "$tsig"; };
options {
    directory "/var/cache/bind";
    listen-on { any; };
    recursion no;
    dnssec-validation no;
};
zone "proxy.test" {
    type primary;
    file "/zones/proxy.test.db";
    update-policy { grant acme zonesub TXT; };
};
CONF
cat > "$work/bind/proxy.test.db" <<'ZONE'
$TTL 60
@   IN SOA ns.proxy.test. admin.proxy.test. 1 60 60 600 60
@   IN NS  ns.proxy.test.
ns  IN A   127.0.0.1
ZONE
chmod -R a+rwX "$work/bind"
docker rm -f via-bind >/dev/null 2>&1
docker run -d --name via-bind -p 127.0.0.1:5353:53/udp -p 127.0.0.1:5353:53/tcp \
    -v "$work/bind/named.conf:/etc/bind/named.conf:ro" -v "$work/bind:/zones" \
    "$BIND_IMAGE" -g -c /etc/bind/named.conf >/dev/null

# proxy stack with its own certificate and webroot directories
[ -f certs/fullchain.pem ] || scripts/dev-cert.sh proxy.test
mkdir -p "$work/certs" "$work/webroot" "$work/letsencrypt"
cp certs/fullchain.pem certs/privkey.pem "$work/certs/"
cp tests/test.env "$env_file"
cat >> "$env_file" <<ENV
VIA_CERT_DIR=$work/certs
VIA_ACME_WEBROOT=$work/webroot
ACME_SERVER=https://localhost:14000/dir
ACME_EAB_KID=kid-1
ACME_EAB_HMAC_KEY=zWNDZM6eQGHWpSRTPal5eIUYFTu7EajVIoguysqZ9wG44nMEtx3MUAsUDkMTQ12W
ACME_CHALLENGE=dns-rfc2136
ACME_RFC2136_SERVER=127.0.0.1
ACME_RFC2136_PORT=5353
ACME_RFC2136_NAME=acme
ACME_RFC2136_SECRET=$tsig
ACME_RFC2136_PROPAGATION=1
ACME_CERTBOT_DIR=$work/letsencrypt
ENV
compose up -d >/dev/null 2>&1 || { echo "compose up failed"; exit 1; }
for _ in $(seq 90); do
    [ "$(curl -s --noproxy '*' http://127.0.0.1:8081/health)" = ok ] && break
    sleep 1
done

served_cert() {
    openssl s_client -connect 127.0.0.1:443 -servername "$1" </dev/null 2>/dev/null |
        openssl x509 -noout -issuer -serial -ext subjectAltName 2>/dev/null
}

r=$(curl -s --noproxy '*' --resolve login.proxy.test:80:127.0.0.1 \
    http://login.proxy.test/.well-known/acme-challenge/missing -o /dev/null -w '%{http_code}')
check "webroot: unknown token 404" has "$r" "404"
mkdir -p "$work/webroot/.well-known/acme-challenge"
echo token-content > "$work/webroot/.well-known/acme-challenge/abc"
r=$(curl -s --noproxy '*' --resolve login.proxy.test:80:127.0.0.1 \
    http://login.proxy.test/.well-known/acme-challenge/abc)
check "webroot: token served on port 80" has "$r" "token-content"
r=$(curl -s --noproxy '*' --resolve login.proxy.test:80:127.0.0.1 \
    -o /dev/null -w '%{http_code} %{redirect_url}' http://login.proxy.test/x)
check "port 80 otherwise redirects to https" has "$r" "301 https://login.proxy.test/x"

for _ in $(seq 30); do
    curl -s --cacert "$work/pebble/ca.pem" --noproxy '*' https://localhost:14000/dir >/dev/null && break
    sleep 1
done
out=$(VIA_ENV_FILE=$env_file REQUESTS_CA_BUNDLE=$work/pebble/ca.pem CERTBOT=$CERTBOT \
      scripts/setup_acme.sh 2>&1)
status=$?
[ "${DEBUG:-}" ] && echo "$out"
check "setup_acme.sh succeeds" test "$status" = 0
check "deploy hook reloaded OpenResty" has "$out" "OpenResty reloaded"

dns_log=$(docker logs via-bind 2>&1)
check "DNS challenge written via RFC 2136" has "$dns_log" "adding an RR at '_acme-challenge.proxy.test' TXT"
check "DNS challenge removed afterwards" has "$dns_log" "deleting an RR at _acme-challenge.proxy.test TXT"
creds_mode=$(stat -c %a "$work/letsencrypt/via-proxy-rfc2136.ini" 2>&1)
check "TSIG credentials file not world-readable" test "$creds_mode" = 600
cert=$(openssl x509 -in "$work/certs/fullchain.pem" -noout -issuer -serial -ext subjectAltName 2>&1)
check "certificate issued by the ACME server" has "$cert" "Pebble"
check "certificate is a wildcard" has "$cert" "DNS:*.proxy.test"
check "certificate covers the proxy domain" has "$cert" "DNS:proxy.test"
served=$(served_cert www-example--publisher-test.proxy.test)
check "OpenResty serves the new certificate" test "$served" = "$cert"

REQUESTS_CA_BUNDLE=$work/pebble/ca.pem "$CERTBOT" renew --force-renewal --quiet \
    --config-dir "$work/letsencrypt" --work-dir "$work/letsencrypt/work" \
    --logs-dir "$work/letsencrypt/logs"
check "renewal succeeds" test "$?" = 0
renewed=$(openssl x509 -in "$work/certs/fullchain.pem" -noout -issuer -serial -ext subjectAltName 2>&1)
check "renewal replaced the certificate" test "$renewed" != "$cert"
check "renewed certificate from the ACME server" has "$renewed" "Pebble"
served=$(served_cert login.proxy.test)
check "OpenResty serves the renewed certificate" test "$served" = "$renewed"
r=$(curl -s --noproxy '*' http://127.0.0.1:8081/health)
check "proxy healthy after renewal" test "$r" = ok
check "private key not world-readable" test "$(stat -c %a "$work/certs/privkey.pem")" = 600

echo "$((total - fail))/$total passed"
if [ "$fail" != 0 ] && [ -n "${CI:-}" ]; then
    echo "$out"
    compose logs --no-color
fi
[ "$fail" = 0 ]
