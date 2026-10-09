-- Unit tests, run inside the OpenResty image:
--   tests/unit.sh
local config = require "via.config"
local hostmap = require "via.hostmap"
local rewrite = require "via.rewrite"
local login = require "via.login"
local limits = require "via.limits"

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

-- usage limits
local lcfg = config.build({
    limits = { window = 100, max_downloads = 2, max_mb = 1, block = 60, contact = "lib" },
    providers = {
        { id = "x", hosts = { "x.org" } },
        { id = "strict", hosts = { "strict.org" }, limits = { max_downloads = 1 } },
        { id = "free", hosts = { "free.org" }, limits = false },
    },
}, "p.org")
local lim = lcfg.limits
eq(lim.max_bytes, 1048576, "limits max_mb")
eq(config.build({ providers = {} }, "p.org").limits, nil, "limits disabled by default")
eq(limits.is_download(lim, 200, "application/pdf"), true, "download pdf")
eq(limits.is_download(lim, 200, "text/html"), false, "download html")
eq(limits.is_download(lim, 200, "text/plain", 'Attachment; filename="a.ris"'), true, "download attachment")
eq(limits.is_download(lim, 404, "application/pdf"), false, "download 404")
eq(limits.is_download(lim, 206, "application/pdf", nil, "bytes 0-65535/900000"), true, "download first range")
eq(limits.is_download(lim, 206, "application/pdf", nil, "bytes 65536-131071/900000"), false, "download later range")

local t = 1000   -- window index 10, start of window
limits.record(lim, "u1", 100, true, t)
limits.record(lim, "u1", 100, true, t + 1)
eq(limits.blocked("u1"), nil, "at limit not blocked")
limits.record(lim, "u1", 100, true, t + 2)
eq(type(limits.blocked("u1")), "string", "over download limit blocked")
local _, ttl = limits.blocked("u1")
eq(ttl > 59 and ttl <= 60, true, "block ttl")
eq(limits.unblock(lcfg, "u1", t + 3), true, "unblock")
eq(limits.blocked("u1"), nil, "unblocked")
local d = limits.record(lim, "u1", 0, false, t + 4)
eq(d, 0, "counters reset after unblock")

limits.record(lim, "u2", 700 * 1024, false, t)
eq(limits.blocked("u2"), nil, "volume below limit")
limits.record(lim, "u2", 400 * 1024, false, t)
eq(type(limits.blocked("u2")), "string", "over volume limit blocked")

-- sliding window: half of the previous window still counts
limits.record(lim, "u3", 0, true, t + 10)
limits.record(lim, "u3", 0, true, t + 20)
d = limits.record(lim, "u3", 0, false, t + 150)   -- next window, 50% elapsed
eq(d, 1, "sliding window weight")
d = limits.record(lim, "u3", 0, false, t + 199)
eq(d < 0.05, true, "sliding window decays")

-- per-provider limits
local strict = config.lookup(lcfg, "strict.org")
local free = config.lookup(lcfg, "free.org")
local x = config.lookup(lcfg, "x.org")
eq(strict.limits.max_downloads, 1, "provider limit threshold")
eq(strict.limits.window, 100, "provider limit inherits window")
eq(strict.limits.block, 60, "provider limit inherits block")
eq(strict.limits.contact, "lib", "provider limit inherits contact")
eq(strict.limits.download_types["application/pdf"], true, "provider limit inherits types")
eq(free.limits, false, "provider exempt")
eq(x.limits, nil, "provider without own limits")

local function keys(rules)
    local out = {}
    for _, r in ipairs(rules) do out[#out + 1] = r.key end
    return table.concat(out, ",")
end
eq(keys(limits.rules(lcfg, x, "u4")), "u4", "rules global only")
eq(keys(limits.rules(lcfg, strict, "u4")), "u4,u4@strict", "rules global and provider")
eq(keys(limits.rules(lcfg, free, "u4")), "", "rules exempt provider")
eq(limits.enabled(lcfg), true, "limits enabled")
local only_provider = config.build({ providers = {
    { id = "s", hosts = { "s.org" }, limits = { max_mb = 5 } } } }, "p.org")
eq(limits.enabled(only_provider), true, "provider limits without global limits")
eq(keys(limits.rules(only_provider, config.lookup(only_provider, "s.org"), "u")), "u@s",
   "rules provider only")
eq(limits.enabled(config.build({ providers = {} }, "p.org")), false, "limits disabled")

limits.record(strict.limits, "u4@strict", 0, true, t)
limits.record(strict.limits, "u4@strict", 0, true, t)
eq(type(limits.blocked("u4@strict")), "string", "provider limit blocks provider")
eq(limits.blocked("u4"), nil, "provider block is not global")
limits.record(lim, "u4", 0, true, t)
limits.record(lim, "u4", 0, true, t)
limits.record(lim, "u4", 0, true, t)
eq(type(limits.blocked("u4")), "string", "global block too")
eq(limits.unblock(lcfg, "u4", t), true, "unblock all")
eq(limits.blocked("u4@strict"), nil, "unblock clears provider block")
eq(limits.blocked("u4"), nil, "unblock clears global block")
eq(limits.unblock(lcfg, "u4", t), false, "unblock nothing left")
local ok = pcall(config.build, { providers = {
    { id = "bad", hosts = { "bad.org" }, limits = "yes" } } }, "p.org")
eq(ok, false, "invalid provider limits rejected")

print(string.format("%d/%d passed", count - failures, count))
os.exit(failures > 0 and 1 or 0)
