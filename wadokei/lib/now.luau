--!nonstrict
-- The current reading at the shell's location, shared by the bar widget and
-- the bell service. Unlike wadokei.luau this uses host globals.

local wadokei = require("./wadokei.luau")

local M = {}

-- Re-read the shell's resolved location this often, in milliseconds.
local LOCATION_TTL_MS = 10 * 60 * 1000

local location = nil
local locationReadAt = nil

local function locationPath()
  local cache = noctalia.getenv("XDG_CACHE_HOME")
  if cache == nil or cache == "" then
    cache = (noctalia.getenv("HOME") or "") .. "/.cache"
  end
  return cache .. "/noctalia/location.json"
end

-- Coordinates from the plugin settings, else the shell's location cache.
local function coordinates()
  local lat = tonumber(noctalia.getConfig("latitude") or "")
  local lon = tonumber(noctalia.getConfig("longitude") or "")
  if lat and lon then
    return lat, lon
  end

  local now = noctalia.nowMs()
  if locationReadAt == nil or now - locationReadAt > LOCATION_TTL_MS then
    locationReadAt = now
    location = nil
    local raw = noctalia.readFile(locationPath())
    if raw then
      local ok, decoded = pcall(noctalia.json.decode, raw)
      if ok and type(decoded) == "table" then
        location = decoded
      end
    end
  end
  if location and tonumber(location.latitude) and tonumber(location.longitude) then
    return tonumber(location.latitude), tonumber(location.longitude)
  end
  return nil
end

-- Unix time of local noon today. Luau's os.time() reads a table as UTC, so
-- the local offset is measured and taken back out.
local function localNoon(now)
  local fields = os.date("*t", now)
  local offset = os.time(fields) - now
  fields.hour, fields.min, fields.sec = 12, 0, 0
  return os.time(fields) - offset
end

-- The reading for right now, in the configured mode. Seasonal mode falls
-- back to fixed hours without a location or without a dawn and dusk.
function M.current()
  local now = os.time()
  if noctalia.getConfig("mode") == "temporal" then
    local lat, lon = coordinates()
    if lat then
      local r = wadokei.temporal(now, localNoon(now), lat, lon)
      if r then
        return r
      end
    end
  end
  local clock = os.date("*t", now)
  return wadokei.fixed({ hour = clock.hour, min = clock.min, sec = clock.sec })
end

return M
