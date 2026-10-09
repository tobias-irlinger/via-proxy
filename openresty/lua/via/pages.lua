-- Small HTML pages served by the proxy itself.
local _M = {}

function _M.escape(s)
    return (tostring(s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

function _M.send(status, title, body_html)
    ngx.status = status
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.say("<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>", _M.escape(title), "</title>",
            "<style>body{font-family:system-ui,sans-serif;max-width:46rem;",
            "margin:2rem auto;padding:0 1rem;line-height:1.5}</style>",
            "</head><body><h1>", _M.escape(title), "</h1>", body_html,
            "</body></html>")
    return ngx.exit(status)
end

-- A host below the proxy domain that is not in providers.json.
function _M.unknown_host(host)
    local link = ""
    if host then
        local url = "https://" .. host .. "/"
        link = "<p>Direkt aufrufen (ohne Lizenzzugang): <a href=\"" ..
               _M.escape(url) .. "\">" .. _M.escape(url) .. "</a></p>"
    end
    return _M.send(404, "Anbieter nicht freigeschaltet",
        "<p>Diese Adresse ist im Bibliotheks-Proxy nicht konfiguriert.</p>" .. link)
end

return _M
