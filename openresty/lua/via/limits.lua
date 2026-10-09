-- Per-user usage limits (like EZproxy's UsageLimit): document downloads and
-- transferred bytes in a sliding window. Exceeding a limit blocks the user
-- for a fixed time. Users are identified by their log pseudonym only.
--
-- State lives in lua_shared_dict via_limits, i.e. per server. With several
-- proxy servers behind a load balancer this would move to Redis.
local cjson = require "cjson.safe"

local _M = {}

_M.DEFAULT_DOWNLOAD_TYPES = {
    "application/pdf", "application/epub+zip", "application/zip",
    "application/octet-stream", "application/x-research-info-systems",
    "application/x-bibtex", "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
}

local function dict()
    return ngx.shared.via_limits
end

-- Turns the "limits" object of providers.json into the runtime config.
function _M.build(l, set_of)
    if not l or l.enabled == false then
        return nil
    end
    assert(l.max_downloads or l.max_mb, "limits: max_downloads or max_mb required")
    return {
        window = l.window or 3600,
        max_downloads = l.max_downloads,
        max_bytes = l.max_mb and l.max_mb * 1024 * 1024,
        block = l.block or 3600,
        contact = l.contact,
        download_types = set_of(l.download_types or _M.DEFAULT_DOWNLOAD_TYPES),
    }
end

-- Sliding window approximation from two fixed windows: the previous window
-- is weighted by how much of it still overlaps the sliding window.
local function count(key, window, now, add)
    local d = dict()
    local idx = math.floor(now / window)
    local cur, err = d:incr(key .. ":" .. idx, add, 0, window * 2)
    if not cur then
        ngx.log(ngx.ERR, "via-limit: cannot count ", key, ": ", err)
        return 0
    end
    local prev = d:get(key .. ":" .. (idx - 1)) or 0
    local elapsed = now - idx * window
    return cur + prev * (1 - elapsed / window)
end

local function reset(user, window, now)
    local d = dict()
    local idx = math.floor(now / window)
    for _, kind in ipairs({ "d", "b" }) do
        d:delete(user .. ":" .. kind .. ":" .. idx)
        d:delete(user .. ":" .. kind .. ":" .. (idx - 1))
    end
end

-- Is this response a document download? Partial responses (PDF viewers use
-- range requests) count only for the first range, so one PDF counts once.
function _M.is_download(limits, status, ctype, disposition, content_range)
    if status == 206 then
        if not (content_range and content_range:match("^%s*bytes%s+0%-")) then
            return false
        end
    elseif status ~= 200 then
        return false
    end
    if ctype and limits.download_types[ctype] then
        return true
    end
    return disposition ~= nil and disposition:lower():find("attachment", 1, true) ~= nil
end

-- Returns reason and remaining seconds if the user is blocked.
function _M.blocked(user)
    local key = "block:" .. user
    local reason = dict():get(key)
    if not reason then
        return nil
    end
    return reason, dict():ttl(key)
end

-- Called in the log phase after each proxied response.
function _M.record(limits, user, bytes, download, now)
    local downloads = count(user .. ":d", limits.window, now, download and 1 or 0)
    local volume = count(user .. ":b", limits.window, now, bytes)

    local reason
    if limits.max_downloads and downloads > limits.max_downloads then
        reason = string.format("%d downloads in %ds (limit %d)",
            downloads, limits.window, limits.max_downloads)
    elseif limits.max_bytes and volume > limits.max_bytes then
        reason = string.format("%.1f MB in %ds (limit %.1f MB)",
            volume / 1048576, limits.window, limits.max_bytes / 1048576)
    end
    if reason and dict():add("block:" .. user, reason, limits.block) then
        -- start from zero once the block expires
        reset(user, limits.window, now)
        ngx.log(ngx.WARN, "via-limit: user ", user, " blocked for ",
                limits.block, "s: ", reason)
    end
    return downloads, volume
end

function _M.unblock(limits, user, now)
    local existed = dict():get("block:" .. user) ~= nil
    dict():delete("block:" .. user)
    reset(user, limits.window, now)
    return existed
end

-- Admin API on the local-only port (see nginx.conf):
--   GET  /limits               blocked users
--   GET  /limits?user=<id>     current counters of one user
--   POST /limits?unblock=<id>  lift a block
function _M.admin(limits)
    ngx.header["Content-Type"] = "application/json"
    if not limits then
        ngx.status = 404
        return ngx.say(cjson.encode({ error = "limits disabled" }))
    end
    local args = ngx.req.get_uri_args()
    local now = ngx.now()

    if args.unblock then
        if ngx.req.get_method() ~= "POST" then
            ngx.status = 405
            return ngx.say(cjson.encode({ error = "use POST" }))
        end
        local existed = _M.unblock(limits, args.unblock, now)
        ngx.log(ngx.WARN, "via-limit: user ", args.unblock, " unblocked by admin")
        return ngx.say(cjson.encode({ user = args.unblock, unblocked = existed }))
    end

    if args.user then
        local reason, ttl = _M.blocked(args.user)
        return ngx.say(cjson.encode({
            user = args.user,
            downloads = count(args.user .. ":d", limits.window, now, 0),
            mb = count(args.user .. ":b", limits.window, now, 0) / 1048576,
            blocked = reason or false,
            blocked_seconds_left = ttl,
        }))
    end

    local blocked = {}
    for _, key in ipairs(dict():get_keys(0)) do
        local user = key:match("^block:(.+)$")
        if user then
            local reason, ttl = _M.blocked(user)
            if reason then
                blocked[#blocked + 1] = { user = user, reason = reason,
                                          seconds_left = ttl }
            end
        end
    end
    setmetatable(blocked, cjson.array_mt)
    return ngx.say(cjson.encode({ blocked = blocked, limits = {
        window = limits.window, max_downloads = limits.max_downloads,
        max_mb = limits.max_bytes and limits.max_bytes / 1048576,
        block = limits.block,
    } }))
end

return _M
