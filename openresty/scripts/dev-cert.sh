#!/bin/sh
# Self-signed wildcard certificate for local tests: ./scripts/dev-cert.sh proxy.test
set -eu
domain=${1:?usage: $0 <proxy-domain>}
dir=$(dirname "$0")/../certs
mkdir -p "$dir"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain,DNS:*.$domain" \
    -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" 2>/dev/null
echo "wrote $dir/fullchain.pem for *.$domain"
