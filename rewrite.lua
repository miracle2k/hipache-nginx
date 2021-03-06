--
-- Based on Paasmaker - Platform as a Service
--
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.
--

-- Include the relevant libraries.
local redis = require("resty.redis")
local red = redis:new()

red:set_timeout(1000)

-- Connect to Redis. Or fail with a 500 server error if we can't.
local ok, err = red:connect(ngx.var.redis_host, ngx.var.redis_port)
if err then
    ngx.log(ngx.ERR, "Unable to connect to redis: " .. err)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

-- Fetch out the Host: header.
local host = ngx.req.get_headers()["Host"]
ngx.log(ngx.DEBUG, host)
if not host then
    -- Check lowercase host.
    host = ngx.req.get_headers()['host']
    ngx.log(ngx.DEBUG, host)
    if not host then
        -- No Host: header? 400, Bad request.
        ngx.log(ngx.DEBUG, "No Host: header")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
end

-- Try to find the Redis script SHA1.
local dict = ngx.shared.redis
local sha1 = nil
if dict ~= nil then
    sha1 = dict:get('sha1')
end

-- Time for Lua-ception. This LUA script is passed to Redis to do
-- the lookups inside the Redis instance. This allows greater
-- hostname probing with less round trips, as well as some other
-- features like sticky sessions.
-- Other notes:
-- * Why not load it as an EVALSHA script? Because then we'd need to
--   know the SHA1, and you might as well send the script anyway.
--   According to the Redis docs, it's cached anyway, so the only
--   overhead is sending the LUA script again.
-- TODO: Use EVALSHA instead of sending the script every time.
local redis_script = [[
-- Helper function to split strings. From http://lua-users.org/wiki/SplitJoin,
-- using the "Function: true Python semantics for split" section.
function string:split(sSeparator, nMax, bRegexp)
    assert(sSeparator ~= '')
    assert(nMax == nil or nMax >= 1)

    local aRecord = {}

    if self:len() > 0 then
        local bPlain = not bRegexp
        nMax = nMax or -1

        local nField=1
        local nStart=1
        local nFirst = self:find(sSeparator, nStart, bPlain)
        local nLast = nFirst
        while nFirst and nMax ~= 0 do
            aRecord[nField] = self:sub(nStart, nFirst-1)
            nField = nField+1
            nStart = nLast+1
            nFirst,nLast = self:find(sSeparator, nStart, bPlain)
            nMax = nMax-1
        end
        aRecord[nField] = self:sub(nStart)
    end

    return aRecord
end

-- Our input is the hostname from the Host: header.
local host = ARGV[1]

-- Convert the incoming hostname to lowercase.
host = host:lower()

-- Strip off any port in the host. This is probably
-- against the HTTP spec, but allows for easier testing,
-- and possibly some other magic scenarios.
local bits = string.split(host, ':')
host = bits[1]

-- Split into parts, then reassemble combinations.
-- We want to end up with an table like: {sub.foo.com, *.foo.com, *.com, *}
local test_hosts = {host}
local host_bits = string.split(host, '.')
for start = 2, #host_bits do
    table.insert(test_hosts, "*." .. table.concat(host_bits, ".", start))
end
table.insert(test_hosts, "*")

-- Return format:
-- {upstream, versiontypekey, nodekey, instancekey, options}

-- The default response - meaning nothing found.
local result = {nil}

for index, hostname in ipairs(test_hosts) do
    -- See if we can find a set with members in it.
    redis.log(redis.LOG_NOTICE, "Key: " .. "frontend:" .. hostname)
    local upstream = redis.call('SRANDMEMBER', "frontend:" .. hostname)

    -- If we found the member... use it.
    if upstream then
        -- redis.log(redis.LOG_NOTICE, "SRANDMEMBER: " .. upstream)
        -- TODO: get auth, ssl info
        result = {upstream}
        break
    end
end

return result
]]

-- SHA1 of script is nil? Load it and save the SHA1.
-- But only if we can save the SHA1, otherwise we're just
-- making two round trips for nothing.
if sha1 == nil and dict ~= nil then
    ngx.log(ngx.DEBUG, "Inserting script into Redis.")
    sha1, err = red:script('load', redis_script)
    if err then
        ngx.log(ngx.ERR, "Redis error: " .. err)
    end
    ngx.log(ngx.DEBUG, "SHA1 stored: ", sha1)
    dict:set('sha1', sha1)
end

ngx.log(ngx.DEBUG, "SHA1 in use: ", sha1)

-- First up, if we have a sha1, attempt to use it.
-- This may fail if the SHA1 is no longer in memory.
-- If it fails, it's caught later.
local res = nil
local err = nil
if sha1 ~= nil then
    ngx.log(ngx.DEBUG, "Using EVALSHA")
    res, err = red:evalsha(sha1, 0, host)
    if err then
        ngx.log(ngx.ERR, "Redis error: " .. err)
        dict:delete('sha1')
    end
end

-- If it fails to run via sha1, we've already made a bunch of round
-- trips, so just exec the script so we can get the response back to
-- the user. We'll try SHA1 next time.
if err or sha1 == nil then
    ngx.log(ngx.WARN, "Fallback - running script directly in Redis")
    res, err = red:eval(redis_script, 0, host)
    if err then
        ngx.log(ngx.ERR, "Redis error: " .. err)
    end
end

if res[1] ~= nil then
    ngx.log(ngx.DEBUG, "Result: ", res[1])
    ngx.log(ngx.DEBUG, "Result: ", res[2])
    ngx.log(ngx.DEBUG, "Result: ", res[3])
    ngx.log(ngx.DEBUG, "Result: ", res[4])
    ngx.log(ngx.DEBUG, "Result: ", res[5])
end

if res[1] ~= nil then
    -- Found. Go upstream.
    ngx.log(ngx.DEBUG, "Found and using upstream " .. res[1])
    ngx.var.upstream = res[1]
else
    -- Not found. 404.
    ngx.log(ngx.DEBUG, "Not found.")
    ngx.exit(ngx.HTTP_NOT_FOUND)
end