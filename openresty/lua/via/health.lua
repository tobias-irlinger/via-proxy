-- Health and status endpoints.
--   /health  (login host and admin port): 200 "ok" or 503, for monitoring
--            and the Docker healthcheck; checks that oauth2-proxy answers.
--   /status  (admin port only): JSON with the loaded provider configuration.
local cjson = require "cjson.safe"
local config = require "via.config"

local _M = {}

local function oauth2_proxy_ok()
    local res = ngx.location.capture("/_via_ping")
    return res.status == 200
end

function _M.health()
    ngx.header["Content-Type"] = "text/plain"
    ngx.header["Cache-Control"] = "no-store"
    if not oauth2_proxy_ok() then
        ngx.status = 503
        return ngx.say("unavailable: oauth2-proxy")
    end
    return ngx.say("ok")
end

function _M.status()
    local cfg = config.current
    local login_ok = oauth2_proxy_ok()
    ngx.header["Content-Type"] = "application/json"
    if not login_ok then
        ngx.status = 503
    end
    return ngx.say(cjson.encode({
        status = login_ok and "ok" or "unavailable",
        oauth2_proxy = login_ok,
        worker = ngx.worker.pid(),
        config = {
            version = cfg.version,
            loaded_at = ngx.http_time(math.floor(cfg.loaded_at)),
            providers = #cfg.providers,
            limits = cfg.limits ~= nil,
            last_error = config.last_error,
        },
    }))
end

return _M
