-- Pure rewriting helpers (no request state), unit tested in tests/unit.lua.
local config = require "via.config"
local hostmap = require "via.hostmap"

local re_gsub = ngx.re.gsub

local _M = {}

-- Absolute and protocol-relative URLs, including JSON-escaped "https:\/\/".
local URL_RE = [[(https?:)?(\\?/\\?/)([a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+)]]

-- Rewrites every URL pointing to an allowlisted host to its proxy host.
-- URLs of other hosts stay untouched.
function _M.urls(cfg, text)
    local out = re_gsub(text, URL_RE, function(m)
        local host = m[3]
        if not config.lookup(cfg, host) then
            return m[0]
        end
        local scheme = m[1] and "https:" or ""
        return scheme .. m[2] .. hostmap.to_proxy(cfg, host)
    end, "joi")
    return out or text
end

-- Reverse direction for request headers (Referer, Origin): proxy URLs are
-- turned back into the original URLs so the provider sees its own hosts.
function _M.unproxy_urls(cfg, text)
    local re = [[https?://([a-z0-9-]+)\.]] .. cfg.proxy_domain:gsub("%.", "\\.") .. [[\b]]
    local out = re_gsub(text, re, function(m)
        local host = hostmap.decode(m[1])
        local provider = host and config.lookup(cfg, host)
        if not provider then
            return m[0]
        end
        return provider.scheme .. "://" .. host
    end, "joi")
    return out or text
end

-- Rewrites one Set-Cookie value from the provider.
--   prefix: cookie name gets "v.<id>." and a Domain attribute is widened to
--           the proxy domain, so all hosts of the provider share it while
--           other providers never see it.
--   host:   Domain attribute is dropped (host-only cookie), name unchanged,
--           for sites whose JavaScript reads its own cookies.
function _M.set_cookie(cfg, provider, value)
    local name, rest = value:match("^%s*([^=;%s]+)%s*=(.*)$")
    if not name then
        return value
    end
    local had_domain = false
    rest = rest:gsub(";%s*[Dd][Oo][Mm][Aa][Ii][Nn]%s*=[^;]*", function()
        had_domain = true
        return ""
    end)
    if provider.cookies == "prefix" then
        name = "v." .. provider.id .. "." .. name
        if had_domain then
            rest = rest .. "; Domain=." .. cfg.proxy_domain
        end
    end
    return name .. "=" .. rest
end

-- Filters the browser's Cookie header for one provider: drops the login
-- cookie and cookies of other providers, strips our own prefix.
function _M.request_cookies(provider, header)
    local prefix = "v." .. provider.id .. "."
    local out = {}
    for pair in header:gmatch("[^;]+") do
        local name, val = pair:match("^%s*([^=]-)%s*=(.*)$")
        if name and name ~= "" then
            if name:find("^_oauth2_proxy") then
                -- never leak the SSO session to the provider
            elseif name:sub(1, #prefix) == prefix then
                out[#out + 1] = name:sub(#prefix + 1) .. "=" .. val
            elseif not name:find("^v%.[a-z0-9]+%.") then
                -- unprefixed: host-only cookie or set by JavaScript
                out[#out + 1] = name .. "=" .. val
            end
        end
    end
    if #out == 0 then
        return nil
    end
    return table.concat(out, "; ")
end

function _M.body(cfg, provider, text, content_type)
    text = _M.urls(cfg, text)
    if content_type == "text/html" or content_type == "application/xhtml+xml" then
        -- Subresource Integrity hashes no longer match rewritten files
        text = re_gsub(text, [[\s+integrity\s*=\s*("[^"]*"|'[^']*')]], "", "joi") or text
    end
    for _, s in ipairs(provider.substitutions) do
        local out, _, err = re_gsub(text, s.pattern, s.replace, "jo")
        if out then
            text = out
        else
            ngx.log(ngx.ERR, "substitution ", s.pattern, " failed: ", err)
        end
    end
    return text
end

return _M
