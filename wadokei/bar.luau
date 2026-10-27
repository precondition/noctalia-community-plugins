--!nonstrict
-- Wadokei bar widget - the current time as a Japanese zodiac hour.
--
-- Shows e.g. 丑の刻 三つ, or 正午 / 正子 for the minute after them. In
-- temporal mode the hours follow dawn and dusk at the shell's location.

local wadokei = require("./lib/wadokei.luau")

-- Re-read the shell's resolved location this often, in milliseconds.
local LOCATION_TTL_MS = 10 * 60 * 1000

local location = nil
local locationReadAt = nil
local lastTooltip = nil

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

local function current()
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

local function hhmm(epoch)
  return os.date("%H:%M", math.floor(epoch + 0.5))
end

local function duration(seconds)
  local minutes = math.floor(seconds / 60 + 0.5)
  return noctalia.tr("tooltip.duration", { hours = minutes // 60, minutes = string.format("%02d", minutes % 60) })
end

local function render()
  local r = current()
  local animal = noctalia.tr("animal." .. r.animal)
  local format = noctalia.getConfig("format") or "{koku} {quarter}"
  local text = wadokei.format(format, r, animal)
  if r.special and noctalia.getConfig("show_special") ~= false then
    text = r.special
  end

  local children = {}
  -- A vertical bar has no room for the label, so it always gets the glyph.
  if noctalia.getConfig("show_glyph") ~= false or barWidget.isVertical() then
    table.insert(children, ui.glyph({ name = r.isDay and "sun" or "moon", color = "primary" }))
  end
  if not barWidget.isVertical() then
    table.insert(children, ui.label({ text = text, color = r.special and "primary" or nil }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))

  local rows = {}
  if r.special then
    table.insert(rows, { noctalia.tr("tooltip.now"), `{r.special}（{r.specialKana}）` })
  end
  table.insert(rows, {
    noctalia.tr("tooltip.hour"),
    `{r.koku}（{r.kokuKana}）· {noctalia.tr("tooltip.hour_of", { animal = animal })}`,
  })
  table.insert(rows, { noctalia.tr("tooltip.quarter"), `{r.quarterText}（{r.quarterKana}）{r.quarter}/4` })
  table.insert(rows, { noctalia.tr("tooltip.bell"), `{r.bell}（{r.bellKana}）` })
  table.insert(rows, { noctalia.tr("tooltip.clock"), os.date("%H:%M") })
  if r.mode == "temporal" then
    table.insert(rows, { "明け六つ（あけむつ）", hhmm(r.dawn) })
    table.insert(rows, { "暮れ六つ（くれむつ）", hhmm(r.dusk) })
    table.insert(rows, { noctalia.tr("tooltip.length"), duration(r.secondsPerKoku) })
  elseif noctalia.getConfig("mode") == "temporal" then
    table.insert(rows, { noctalia.tr("tooltip.mode"), noctalia.tr("tooltip.no_location") })
  end
  local encoded = noctalia.json.encode(rows)
  if encoded ~= lastTooltip then
    lastTooltip = encoded
    barWidget.setTooltip(rows)
  end

  -- Wake up when the reading changes, but at least every minute so the
  -- tooltip's clock and setting changes stay current.
  local ms = math.ceil(r.untilChange * 1000) + 50
  noctalia.setUpdateInterval(math.clamp(ms, 1000, 60000))
end

function update()
  render()
end
