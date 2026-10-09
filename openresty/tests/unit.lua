-- Unit tests, run inside the OpenResty image:
--   tests/unit.sh
local config = require "via.config"
local hostmap = require "via.hostmap"
local rewrite = require "via.rewrite"
local login = require "via.login"

local failures, count = 0, 0
local function eq(got, want, what)
    count = count + 1
    if got ~= want then
        failures = failures + 1
        print("FAIL " .. what .. "\n  got:  " .. tostring(got) .. "\n  want: " .. tostring(want))
    end
end

local cfg = config.build({
    providers = {
        { id = "jstor", hosts = { "www.jstor.org", ".jstor.org" } },
        { id = "some", hosts = { "www.some-site.co.uk" }, cookies = "host",
          substitutions = { { pattern = [["apiHost":"www\.some-site\.co\.uk"]],
                              replace = [["apiHost":"www-some--site-co-uk.{proxy_domain}"]] } } },
    },
}, "Proxy.Example.org")
local jstor = config.lookup(cfg, "www.jstor.org")
local some = config.lookup(cfg, "www.some-site.co.uk")

-- hostmap
eq(hostmap.encode("www.jstor.org"), "www-jstor-org", "encode simple")
eq(hostmap.encode("www.some-site.co.uk"), "www-some--site-co-uk", "encode hyphen")
eq(hostmap.decode("www-some--site-co-uk"), "www.some-site.co.uk", "decode hyphen")
eq(hostmap.decode(hostmap.encode("xn--bcher-kva.example")), "xn--bcher-kva.example", "punycode roundtrip")
eq(hostmap.decode("a---b"), nil, "decode invalid")
eq(hostmap.decode("-abc"), nil, "decode leading hyphen")
eq(hostmap.from_proxy(cfg, "www-jstor-org.proxy.example.org"), "www.jstor.org", "from_proxy")
eq(hostmap.from_proxy(cfg, "a.www-jstor-org.proxy.example.org"), nil, "from_proxy two labels")
eq(hostmap.from_proxy(cfg, "www-jstor-org.proxy.example.org.evil"), nil, "from_proxy foreign")

-- lookup
eq(config.lookup(cfg, "WWW.JSTOR.ORG"), jstor, "lookup case")
eq(config.lookup(cfg, "cdn.assets.jstor.org"), jstor, "lookup suffix")
eq(config.lookup(cfg, "jstor.org.evil.com"), nil, "lookup no false suffix")
eq(config.lookup(cfg, "notjstor.org"), nil, "lookup label boundary")

-- URL rewriting
eq(rewrite.urls(cfg, 'href="https://www.jstor.org/stable/1"'),
   'href="https://www-jstor-org.proxy.example.org/stable/1"', "urls https")
eq(rewrite.urls(cfg, 'href="http://www.jstor.org/"'),
   'href="https://www-jstor-org.proxy.example.org/"', "urls http upgraded")
eq(rewrite.urls(cfg, 'src="//cdn.jstor.org/a.js"'),
   'src="//cdn-jstor-org.proxy.example.org/a.js"', "urls protocol relative")
eq(rewrite.urls(cfg, [["https:\/\/www.jstor.org\/x"]]),
   [["https:\/\/www-jstor-org.proxy.example.org\/x"]], "urls json escaped")
eq(rewrite.urls(cfg, 'href="https://www.google.com/"'),
   'href="https://www.google.com/"', "urls foreign untouched")
eq(rewrite.urls(cfg, 'https://www.jstor.org.evil.com/'),
   'https://www.jstor.org.evil.com/', "urls lookalike untouched")
eq(rewrite.unproxy_urls(cfg, "https://www-jstor-org.proxy.example.org/search?q=1"),
   "https://www.jstor.org/search?q=1", "unproxy referer")
eq(rewrite.unproxy_urls(cfg, "https://login.proxy.example.org/"),
   "https://login.proxy.example.org/", "unproxy login host untouched")

-- body
eq(rewrite.body(cfg, jstor, '<script src="https://www.jstor.org/a.js" integrity="sha384-abc"></script>', "text/html"),
   '<script src="https://www-jstor-org.proxy.example.org/a.js"></script>', "body strips integrity")
eq(rewrite.body(cfg, some, '{"apiHost":"www.some-site.co.uk"}', "application/json"),
   '{"apiHost":"www-some--site-co-uk.proxy.example.org"}', "body provider substitution")

-- cookies
eq(rewrite.set_cookie(cfg, jstor, "JSESSIONID=1; Domain=.jstor.org; Path=/; Secure"),
   "v.jstor.JSESSIONID=1; Path=/; Secure; Domain=.proxy.example.org", "set_cookie prefix domain")
eq(rewrite.set_cookie(cfg, jstor, "a=1; Path=/"), "v.jstor.a=1; Path=/", "set_cookie prefix hostonly")
eq(rewrite.set_cookie(cfg, some, "XSRF-TOKEN=t; domain=some-site.co.uk; path=/"),
   "XSRF-TOKEN=t; path=/", "set_cookie host mode")
eq(rewrite.request_cookies(jstor, "_oauth2_proxy=s; v.jstor.JSESSIONID=1; v.wiley.x=2; js=3"),
   "JSESSIONID=1; js=3", "request_cookies filter")
eq(rewrite.request_cookies(jstor, "_oauth2_proxy=s"), nil, "request_cookies only sso")

-- starting point
eq(login.target_from_args("url=https://www.jstor.org/stable/1?a=b&c=d"),
   "https://www.jstor.org/stable/1?a=b&c=d", "url= takes rest")
eq(login.target_from_args("url=https%3A%2F%2Fwww.jstor.org%2Fx"), "https://www.jstor.org/x", "url= encoded")
eq(login.target_from_args("qurl=https%3A%2F%2Fwww.jstor.org%2Fx%3Fa%3D1&foo=bar"),
   "https://www.jstor.org/x?a=1", "qurl=")
eq(login.target_from_args("foo=bar"), nil, "no url")
local h, rest = login.split_url("https://WWW.JSTOR.ORG?q=1")
eq(h .. " " .. rest, "www.jstor.org /?q=1", "split_url no path")
eq(login.split_url("https://www.jstor.org:8443/"), nil, "split_url port rejected")
eq(login.split_url("https://user@www.jstor.org/"), nil, "split_url userinfo rejected")
eq(login.split_url("javascript:alert(1)"), nil, "split_url non-http")

print(string.format("%d/%d passed", count - failures, count))
os.exit(failures > 0 and 1 or 0)
