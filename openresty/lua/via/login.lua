-- Login host (login.<proxy_domain>): starting-point URLs and provider menu.
local config = require "via.config"
local hostmap = require "via.hostmap"
local pages = require "via.pages"

local _M = {}

-- Extracts the target URL from an EZproxy-compatible query string:
--   url=<URL>   everything after "url=" is the target, may be unencoded
--   qurl=<URL>  percent-encoded target, may be followed by other params
function _M.target_from_args(args)
    if not args or args == "" then
        return nil
    end
    local url = args:match("^url=(.*)$") or args:match("&url=(.*)$")
    if url then
        if url:match("^[Hh][Tt][Tt][Pp][Ss]?%%3[Aa]") then
            url = ngx.unescape_uri(url)
        end
        return url
    end
    local qurl = args:match("^qurl=([^&]*)") or args:match("&qurl=([^&]*)")
    if qurl then
        return ngx.unescape_uri(qurl)
    end
    return nil
end

-- Returns host and the rest (path, query, fragment) of an http(s) URL.
function _M.split_url(url)
    local host, rest = url:match("^[Hh][Tt][Tt][Pp][Ss]?://([^/?#:@]+)(.*)$")
    if not host or rest:match("^[:@]") then
        return nil   -- no host, userinfo, or explicit port (not supported)
    end
    if rest == "" or not rest:match("^/") then
        rest = "/" .. rest
    end
    return host:lower(), rest
end

-- /login?url=https://www.jstor.org/stable/123
--   -> https://www-jstor-org.<proxy_domain>/stable/123
-- The provider host then asks oauth2-proxy and starts the OIDC login if
-- there is no session yet.
function _M.start()
    local cfg = config.current
    local url = _M.target_from_args(ngx.var.args)
    if not url then
        return pages.send(400, "Ungültiger Link",
            "<p>Es fehlt der Parameter <code>url=</code>.</p>")
    end
    local host, rest = _M.split_url(url)
    local provider = host and config.lookup(cfg, host)
    if not provider then
        return pages.send(403, "Anbieter nicht freigeschaltet",
            "<p>Für diese Adresse ist kein Zugang über den Bibliotheks-Proxy " ..
            "eingerichtet.</p><p><a href=\"" .. pages.escape(url) ..
            "\">Direkt aufrufen</a></p>")
    end
    if ngx.var.via_campus == "1" then
        return ngx.redirect(provider.scheme .. "://" .. host .. rest)
    end
    return ngx.redirect("https://" .. hostmap.to_proxy(cfg, host) .. rest)
end

-- Start page with all configured providers.
function _M.menu()
    local cfg = config.current
    local items = {}
    for _, p in ipairs(cfg.providers) do
        items[#items + 1] = "<li><a href=\"/login?url=" ..
            pages.escape(p.start) .. "\">" .. pages.escape(p.name) .. "</a></li>"
    end
    return pages.send(200, "E-Ressourcen",
        "<ul>" .. table.concat(items) .. "</ul>" ..
        "<p><a href=\"/oauth2/sign_out\">Abmelden</a></p>")
end

return _M
