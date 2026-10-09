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

-- User exceeded a usage limit (see via.limits).
function _M.blocked(ttl, contact)
    local seconds = math.ceil(tonumber(ttl) or 60)
    local minutes = math.max(1, math.ceil(seconds / 60))
    ngx.header["Retry-After"] = tostring(seconds)
    local contact_html = ""
    if contact then
        contact_html = "<p>Bei Fragen: " .. _M.escape(contact) .. "</p>"
    end
    return _M.send(429, "Zugang vorübergehend gesperrt",
        "<p>Über Ihre Kennung wurden in kurzer Zeit ungewöhnlich viele " ..
        "Dokumente bzw. Daten abgerufen. Systematisches Herunterladen ist " ..
        "nach den Lizenzbedingungen der Anbieter nicht erlaubt und kann zur " ..
        "Sperrung des Zugangs für die gesamte Hochschule führen.</p>" ..
        "<p>Die Sperre endet automatisch in etwa " .. minutes ..
        " Minuten.</p>" .. contact_html)
end

return _M
