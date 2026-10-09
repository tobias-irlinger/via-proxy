#!/bin/bash
# End-to-end test: OpenResty + oauth2-proxy + mock OIDC IdP + fake publisher.
#   tests/e2e.sh          start stack, run tests, stop stack
#   KEEP=1 tests/e2e.sh   leave the stack running afterwards
set -u
cd "$(dirname "$0")/.."

compose() {
    docker compose --env-file tests/test.env \
        -f docker-compose.yml -f tests/docker-compose.test.yml "$@"
}

work=$(mktemp -d)
cleanup() {
    [ "${KEEP:-}" = 1 ] || compose down -v >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

[ -f certs/fullchain.pem ] || scripts/dev-cert.sh proxy.test
compose up -d >/dev/null 2>&1 || { echo "compose up failed"; exit 1; }

PUB=www-example--publisher-test.proxy.test
CDN=cdn-example--publisher-test.proxy.test
c() {
    curl -sk --noproxy '*' \
        --resolve login.proxy.test:443:127.0.0.1 \
        --resolve $PUB:443:127.0.0.1 \
        --resolve $CDN:443:127.0.0.1 \
        --resolve www-google-com.proxy.test:443:127.0.0.1 \
        --resolve mock-idp:8080:127.0.0.1 \
        -c "$jar" -b "$jar" "$@"
}

fail=0 total=0
check() {   # check <description> <command...>
    total=$((total + 1))
    local desc=$1; shift
    if "$@"; then
        echo "ok   $desc"
    else
        echo "FAIL $desc"
        [ -n "${DEBUG:-}" ] && printf '     got: %.300s\n' "$2"
        fail=$((fail + 1))
    fi
}
has() { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }

# wait until oauth2-proxy has finished OIDC discovery
for _ in $(seq 60); do
    jar=/dev/null
    code=$(c -o /dev/null -w '%{http_code}' https://login.proxy.test/oauth2/start)
    [ "$code" = 302 ] && break
    sleep 1
done

# login <user> <affiliation> <target url>
#   prints the callback status and the URL it redirects to
login() {
    local loc
    loc=$(c -o /dev/null -w '%{redirect_url}' "$3")                 # -> login host
    loc=$(c -o /dev/null -w '%{redirect_url}' "$loc")               # -> IdP
    loc=$(c -o /dev/null -w '%{redirect_url}' "$loc" \
        --data-urlencode "username=$1" \
        --data-urlencode "claims={\"eduperson_scoped_affiliation\":[\"$2\"]}")  # -> callback
    c -o /dev/null -w '%{http_code} %{redirect_url}' "$loc"
}

jar=$work/alice
target="https://$PUB/echo?a=1&b=2"

r=$(c -o /dev/null -w '%{http_code} %{redirect_url}' \
    "https://login.proxy.test/login?url=https://www.example-publisher.test/echo?a=1&b=2")
check "starting point maps to proxy host" has "$r" "302 $target"

r=$(c -o /dev/null -w '%{http_code} %{redirect_url}' "$target")
check "no session -> login redirect" has "$r" "302 https://login.proxy.test/oauth2/start?rd="

# (the mock IdP drops "&b=2" from the state, so log in with a simpler URL)
r=$(login alice member@example.org "https://$PUB/echo?a=1")
check "login redirects back to target" has "$r" "302 https://$PUB/echo?a=1"
r=$(c "$target")
check "proxied request reaches provider" has "$r" "host=www.example-publisher.test"
check "query string preserved" has "$(compose logs upstream 2>/dev/null)" "GET /echo?a=1&b=2"
check "SSO cookie not sent upstream" hasnt "$r" "_oauth2_proxy"
check "Accept-Encoding removed" grep -qx "accept_encoding=" <<<"$r"

h=$(c -D - -o "$work/page" "https://$PUB/")
p=$(cat "$work/page")
check "absolute link rewritten" has "$p" "href=\"https://$PUB/article/1\""
check "http link upgraded" has "$p" "href=\"https://$PUB/article/2\""
check "protocol-relative link rewritten" has "$p" "src=\"//$CDN/app.js\""
check "JSON-escaped URL rewritten" has "$p" "https:\\/\\/$PUB\\/api"
check "integrity attribute removed" hasnt "$p" "integrity="
check "foreign link untouched" has "$p" "https://unknown.example.net/"
check "domain cookie prefixed and widened" has "$h" "v.publisher.session=abc; Path=/; Secure; HttpOnly; Domain=.proxy.test"
check "host-only cookie prefixed" has "$h" "v.publisher.hostonly=1; Path=/"
check "CSP removed" hasnt "$h" "content-security-policy"

r=$(c "https://$PUB/echo")
check "provider cookie sent unprefixed" has "$r" "session=abc"
check "host-only cookie sent unprefixed" has "$r" "hostonly=1"
r=$(c "https://$CDN/")
check "domain cookie shared with other provider host" has "$r" "cdn cookie=session=abc"
check "host-only cookie not shared" hasnt "$r" "hostonly"

r=$(c -o /dev/null -w '%{http_code} %{redirect_url}' "https://$PUB/redirect")
check "Location rewritten" has "$r" "302 https://$CDN/file.pdf"

r=$(c -H "Referer: https://$PUB/search?q=x" "https://$PUB/echo")
check "Referer mapped back to original" has "$r" "referer=http://www.example-publisher.test/search?q=x"

r=$(c -o /dev/null -w '%{http_code}' "https://www-google-com.proxy.test/")
check "unknown host -> 404" has "$r" "404"
r=$(c -o /dev/null -w '%{http_code}' "https://login.proxy.test/login?url=https://www.google.com/")
check "starting point for unknown host -> 403" has "$r" "403"

jar=$work/bob
r=$(login bob affiliate@example.org "$target")
check "non-member is rejected at login" has "$r" "403"
r=$(c -o /dev/null -w '%{http_code}' "$target")
check "non-member gets no session" has "$r" "302"

# usage limits (tests/providers.test.json: 3 downloads or 1 MB per hour)
admin() { curl -s --noproxy '*' "$@"; }
jar=$work/carol
login carol member@example.org "https://$PUB/echo" >/dev/null
for i in 1 2 3; do
    r=$(c -o /dev/null -w '%{http_code}' "https://$PUB/doc.pdf")
done
check "downloads up to the limit pass" has "$r" "200"
r=$(c -o /dev/null -w '%{http_code}' "https://$PUB/export")
check "download over the limit still delivered" has "$r" "200"
r=$(c -D - "https://$PUB/echo")
check "user blocked after exceeding downloads" has "$r" "HTTP/2 429"
check "block page has Retry-After" has "$r" "retry-after: 12"
check "block page names contact" has "$r" "test@example.org"
r=$(admin http://127.0.0.1:8081/limits)
check "admin API lists blocked user" has "$r" "4 downloads in 3600s (limit 3)"
user=$(sed -n 's/.*"user":"\([0-9a-f]*\)".*/\1/p' <<<"$r")
r=$(admin -o /dev/null -w '%{http_code}' "http://127.0.0.1:8081/limits?unblock=$user")
check "admin unblock requires POST" has "$r" "405"
r=$(admin -X POST "http://127.0.0.1:8081/limits?unblock=$user")
check "admin unblock" has "$r" '"unblocked":true'
r=$(c -o /dev/null -w '%{http_code}' "https://$PUB/doc.pdf")
check "unblocked user has access again" has "$r" "200"

jar=$work/dave
login dave member@example.org "https://$PUB/echo" >/dev/null
c -o /dev/null "https://$PUB/big"
r=$(c -o /dev/null -w '%{http_code}' "https://$PUB/big")
check "volume up to the limit passes" has "$r" "200"
r=$(c -o /dev/null -w '%{http_code}' "https://$PUB/echo")
check "user blocked after exceeding volume" has "$r" "429"

jar=$work/alice
r=$(c -o /dev/null -w '%{http_code}' "https://$PUB/doc.pdf")
check "other users unaffected" has "$r" "200"

logs=$(compose logs openresty 2>/dev/null)
check "block is logged with pseudonym" has "$logs" "via-limit: user $user blocked"
check "access log has no plain user id" hasnt "$logs" "alice"

echo "$((total - fail))/$total passed"
[ "$fail" = 0 ]
