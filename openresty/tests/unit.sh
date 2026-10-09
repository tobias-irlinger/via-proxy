#!/bin/sh
# Runs tests/unit.lua inside the OpenResty image (init phase of a throwaway nginx).
set -eu
cd "$(dirname "$0")/.."
exec docker run --rm -v "$PWD":/w:ro --entrypoint openresty \
    openresty/openresty:1.27.1.2-bookworm \
    -p /tmp -e stderr -c /w/tests/unit.nginx.conf -g 'daemon off; master_process off; error_log stderr crit;'
