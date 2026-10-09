-- Loads providers.json in init_by_lua, builds the host allowlist and
-- reloads it in every worker when the file changes (see watch()).
local cjson = require "cjson.safe"
local limits = require "via.limits"

local _M = {}

local DEFAULT_CONTENT_TYPES = {
    "text/html", "application/xhtml+xml", "text/css",
    "application/javascript", "text/javascript", "application/json",
}

local function read_file(path)
    local fh, err = io.open(path, "r")
    if not fh then
        error("cannot read " .. path .. ": " .. tostring(err))
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

local function set_of(list)
    local set = {}
    for _, v in ipairs(list) do
        set[v:lower()] = true
    end
    return set
end

-- Builds the config table from already decoded JSON. Kept separate from
-- init() so unit tests can feed data without touching the file system.
function _M.build(data, proxy_domain)
    assert(type(proxy_domain) == "string" and proxy_domain ~= "",
           "PROXY_DOMAIN is not set")
    proxy_domain = proxy_domain:lower()

    local defaults = data.defaults or {}
    local cfg = {
        proxy_domain = proxy_domain,
        login_host = "login." .. proxy_domain,
        max_rewrite_bytes = defaults.max_rewrite_bytes or 10 * 1024 * 1024,
        providers = {},
        exact = {},     -- host -> provider
        suffixes = {},  -- ".example.com" -> provider
    }
    local default_types = defaults.content_types or DEFAULT_CONTENT_TYPES
    cfg.limits = limits.build(data.limits, set_of)

    for i, p in ipairs(data.providers or {}) do
        assert(type(p.id) == "string" and p.id:match("^[a-z0-9]+$"),
               "provider #" .. i .. ": id must match [a-z0-9]+")
        assert(type(p.hosts) == "table" and #p.hosts > 0,
               "provider " .. p.id .. ": hosts missing")

        local subs = {}
        for _, s in ipairs(p.substitutions or {}) do
            subs[#subs + 1] = {
                pattern = s.pattern,
                replace = (s.replace:gsub("{proxy_domain}", proxy_domain)),
            }
        end

        local provider = {
            id = p.id,
            name = p.name or p.id,
            start = p.start or ("https://" .. p.hosts[1]:gsub("^%.", "") .. "/"),
            scheme = p.scheme or "https",
            cookies = p.cookies or "prefix",
            content_types = set_of(p.content_types or default_types),
            substitutions = subs,
            limits = limits.build_provider(p.limits, cfg.limits, set_of),
        }
        assert(provider.cookies == "prefix" or provider.cookies == "host",
               "provider " .. p.id .. ": cookies must be 'prefix' or 'host'")

        for _, h in ipairs(p.hosts) do
            h = h:lower()
            local tbl = h:sub(1, 1) == "." and cfg.suffixes or cfg.exact
            assert(not tbl[h], "host " .. h .. " is listed twice")
            tbl[h] = provider
        end
        cfg.providers[#cfg.providers + 1] = provider
    end

    return cfg
end

local function path()
    return os.getenv("VIA_PROVIDERS") or "/etc/via/config/providers.json"
end

-- Parses and validates the file content. Returns cfg or nil, error.
local function load(text)
    local data, err = cjson.decode(text)
    if not data then
        return nil, "cannot parse " .. path() .. ": " .. err
    end
    local ok, cfg = pcall(_M.build, data, os.getenv("PROXY_DOMAIN"))
    if not ok then
        return nil, "invalid " .. path() .. ": " .. tostring(cfg)
    end
    cfg.log_key = os.getenv("VIA_LOG_KEY") or ""
    cfg.source = text
    cfg.version = ngx.md5(text):sub(1, 12)
    cfg.loaded_at = ngx.now()
    return cfg
end

-- init_by_lua: a broken file stops nginx from starting (or a reload from
-- being applied), so mistakes show up immediately.
function _M.init()
    local cfg, err = load(read_file(path()))
    if not cfg then
        error(err)
    end
    _M.current = cfg
end

-- Re-reads the file if its content changed. A broken file is logged and
-- ignored, the previous configuration stays active.
function _M.reload_if_changed()
    local fh = io.open(path(), "r")
    if not fh then
        ngx.log(ngx.ERR, "via-config: cannot read ", path())
        return false
    end
    local text = fh:read("*a")
    fh:close()
    if text == _M.current.source then
        return false
    end
    local cfg, err = load(text)
    if not cfg then
        ngx.log(ngx.ERR, "via-config: keeping version ", _M.current.version, ": ", err)
        _M.current.source = text   -- do not log the same error every interval
        _M.last_error = err
        return false
    end
    _M.current = cfg
    _M.last_error = nil
    ngx.log(ngx.NOTICE, "via-config: loaded version ", cfg.version, " with ",
            #cfg.providers, " providers")
    return true
end

-- init_worker_by_lua: poll the file every VIA_RELOAD_INTERVAL seconds
-- (default 5, 0 disables). Each worker keeps its own copy.
function _M.watch()
    local interval = tonumber(os.getenv("VIA_RELOAD_INTERVAL") or "5") or 5
    if interval <= 0 then
        return
    end
    local ok, err = ngx.timer.every(interval, function(premature)
        if not premature then
            _M.reload_if_changed()
        end
    end)
    if not ok then
        ngx.log(ngx.ERR, "via-config: cannot start watcher: ", err)
    end
end

-- Returns the provider responsible for an original host, or nil.
function _M.lookup(cfg, host)
    host = host:lower()
    local p = cfg.exact[host]
    if p then
        return p
    end
    -- walk ".a.b.c", ".b.c", ".c"
    local pos = host:find(".", 1, true)
    while pos do
        p = cfg.suffixes[host:sub(pos)]
        if p then
            return p
        end
        pos = host:find(".", pos + 1, true)
    end
    return nil
end

return _M
