-- Loads providers.json once in init_by_lua and builds the host allowlist.
local cjson = require "cjson.safe"

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

function _M.init()
    local path = os.getenv("VIA_PROVIDERS") or "/etc/via/providers.json"
    local data, err = cjson.decode(read_file(path))
    if not data then
        error("cannot parse " .. path .. ": " .. err)
    end
    _M.current = _M.build(data, os.getenv("PROXY_DOMAIN"))
    _M.current.log_key = os.getenv("VIA_LOG_KEY") or ""
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
