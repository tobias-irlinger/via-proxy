-- Maps original hosts to proxy hosts and back, using the EZproxy
-- "proxy by hostname" scheme: "-" becomes "--", then "." becomes "-".
--   www.jstor.org       <-> www-jstor-org.<proxy_domain>
--   www.some-site.co.uk <-> www-some--site-co-uk.<proxy_domain>
-- Every proxy host is a single label below the proxy domain, so one
-- wildcard certificate *.<proxy_domain> covers all of them.
local _M = {}

function _M.encode(host)
    return (host:lower():gsub("%-", "--"):gsub("%.", "-"))
end

-- Returns nil for labels that cannot be produced by encode().
function _M.decode(label)
    label = label:lower()
    if not label:match("^[a-z0-9][a-z0-9-]*[a-z0-9]$") then
        return nil
    end
    -- "_" cannot occur in a validated label, so it is a safe placeholder
    local host = label:gsub("%-%-", "_"):gsub("%-", "."):gsub("_", "-")
    if host:find("..", 1, true) or host:find("%.%-") or host:find("%-%.") then
        return nil
    end
    return host
end

function _M.to_proxy(cfg, host)
    return _M.encode(host) .. "." .. cfg.proxy_domain
end

-- "www-jstor-org.proxy.example.org" -> "www.jstor.org", or nil
function _M.from_proxy(cfg, proxy_host)
    proxy_host = proxy_host:lower()
    local suffix = "." .. cfg.proxy_domain
    if #proxy_host <= #suffix or proxy_host:sub(-#suffix) ~= suffix then
        return nil
    end
    local label = proxy_host:sub(1, -#suffix - 1)
    if label:find(".", 1, true) then
        return nil
    end
    return _M.decode(label)
end

return _M
