-- Request phases for the provider hosts (*.<proxy_domain>).
local config = require "via.config"
local hostmap = require "via.hostmap"
local rewrite = require "via.rewrite"
local pages = require "via.pages"
local limits = require "via.limits"

local str = require "resty.string"

local _M = {}

-- URL-valued response headers that may point back to the provider
local URL_HEADERS = {
    "Location", "Content-Location", "Refresh", "Link",
    "Access-Control-Allow-Origin",
}

-- rewrite_by_lua: map the proxy host to the provider, campus bypass,
-- clean up the request before it goes upstream.
function _M.rewrite()
    local cfg = config.current
    local host = hostmap.from_proxy(cfg, ngx.var.host)
    local provider = host and config.lookup(cfg, host)
    if not provider then
        return pages.unknown_host(host)
    end

    if ngx.var.via_campus == "1" then
        return ngx.redirect(provider.scheme .. "://" .. host .. ngx.var.request_uri)
    end

    ngx.ctx.provider = provider
    ngx.var.via_provider = provider.id
    ngx.var.via_upstream_host = host
    ngx.var.via_scheme = provider.scheme

    -- Only nginx variables are changed here, not the request headers: the
    -- auth_request subrequest still needs the original Cookie header with
    -- the SSO session. proxy_set_header sends the cleaned values upstream.
    local cookie = ngx.var.http_cookie
    if cookie then
        ngx.var.via_cookie = rewrite.request_cookies(provider, cookie) or ""
    end
    local referer = ngx.var.http_referer
    if referer then
        ngx.var.via_referer = rewrite.unproxy_urls(cfg, referer)
    end
    local origin = ngx.var.http_origin
    if origin then
        ngx.var.via_origin = rewrite.unproxy_urls(cfg, origin)
    end
end

-- error_page 401 target: send the browser to the login host.
function _M.login_redirect()
    local cfg = config.current
    local rd = "https://" .. ngx.var.host .. ngx.var.request_uri
    return ngx.redirect("https://" .. cfg.login_host
        .. "/oauth2/start?rd=" .. ngx.escape_uri(rd))
end

local function pseudonym(user)
    if not user or user == "" then
        return nil
    end
    return str.to_hex(ngx.hmac_sha1(config.current.log_key, user)):sub(1, 16)
end

-- access_by_lua: runs after auth_request, so the user is known here.
function _M.access()
    local user = pseudonym(ngx.var.via_user)
    if not user then
        return
    end
    ngx.ctx.user = user
    ngx.var.via_user_hash = user

    local rules = limits.rules(config.current, ngx.ctx.provider, user)
    ngx.ctx.rules = rules
    for _, rule in ipairs(rules) do
        local reason, ttl = limits.blocked(rule.key)
        if reason then
            ngx.ctx.blocked = true
            return pages.blocked(ttl, rule.limits.contact)
        end
    end
end

function _M.header_filter()
    local provider = ngx.ctx.provider
    if not provider then
        return
    end
    local cfg = config.current

    for _, name in ipairs(URL_HEADERS) do
        local value = ngx.header[name]
        if type(value) == "string" then
            ngx.header[name] = rewrite.urls(cfg, value)
        end
    end

    local cookies = ngx.header["Set-Cookie"]
    if cookies then
        if type(cookies) == "string" then
            cookies = { cookies }
        end
        for i, c in ipairs(cookies) do
            cookies[i] = rewrite.set_cookie(cfg, provider, c)
        end
        ngx.header["Set-Cookie"] = cookies
    end

    -- host-sources in a CSP would block the proxy hosts
    ngx.header["Content-Security-Policy"] = nil
    ngx.header["Content-Security-Policy-Report-Only"] = nil

    local ctype = (ngx.header["Content-Type"] or ""):match("^%s*([^;%s]+)")
    ctype = ctype and ctype:lower()
    local status = ngx.status

    for _, rule in ipairs(ngx.ctx.rules or {}) do
        rule.download = limits.is_download(rule.limits, status, ctype,
            ngx.header["Content-Disposition"], ngx.header["Content-Range"])
    end
    if ctype and provider.content_types[ctype]
            and not ngx.header["Content-Encoding"]
            and status ~= 204 and status ~= 304
            and ngx.req.get_method() ~= "HEAD" then
        local len = tonumber(ngx.header["Content-Length"])
        if not len or len <= cfg.max_rewrite_bytes then
            ngx.ctx.rewrite_type = ctype
            ngx.ctx.buf = {}
            ngx.ctx.size = 0
            ngx.header["Content-Length"] = nil
        end
    end
end

-- Buffers the whole body (up to max_rewrite_bytes) so that URLs split
-- across chunks are rewritten, then emits it in one piece.
function _M.body_filter()
    local ctx = ngx.ctx
    if not ctx.rewrite_type then
        return
    end
    local chunk, eof = ngx.arg[1], ngx.arg[2]
    if chunk ~= "" then
        ctx.buf[#ctx.buf + 1] = chunk
        ctx.size = ctx.size + #chunk
    end

    if ctx.size > config.current.max_rewrite_bytes then
        -- too large: give up rewriting, pass everything through unchanged
        ngx.log(ngx.WARN, "body too large to rewrite: ", ngx.var.request_uri)
        ngx.arg[1] = table.concat(ctx.buf)
        ctx.rewrite_type = nil
        ctx.buf = nil
        return
    end

    if not eof then
        ngx.arg[1] = nil
        return
    end
    ngx.arg[1] = rewrite.body(config.current, ctx.provider,
                              table.concat(ctx.buf), ctx.rewrite_type)
    ctx.buf = nil
end

function _M.log()
    local ctx = ngx.ctx
    if not ctx.rules or ctx.blocked then
        return
    end
    local bytes, now = tonumber(ngx.var.bytes_sent) or 0, ngx.now()
    for _, rule in ipairs(ctx.rules) do
        limits.record(rule.limits, rule.key, bytes, rule.download, now)
    end
end

return _M
