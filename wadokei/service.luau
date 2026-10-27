--!nonstrict
-- Wadokei bell service - rings the temple bell (時の鐘) at each hour.
--
-- A service rather than the bar widget, so it rings once however many bars
-- show the widget. With `bell = "count"` it strikes as many times as the
-- hour's name (九つ is nine strokes); with "once" it strikes once.

local now = require("./lib/now.luau")

-- Time between strokes, in milliseconds. The sample rings for 7 s, so
-- strokes alternate between two loaded copies: the host will not restart a
-- sound that is still playing.
local STROKE_GAP_MS = 4000
local SLOTS = { "bell1", "bell2" }

-- A bell still rings if the service notices it this late, in seconds.
local LATE_WINDOW = 120

local loaded = {}
local slot = 0
local strokesLeft = 0
local nextStrokeAt = 0
-- Index of the koku whose bell was last handled, rung or not. nil until the
-- first update, so a bell that rang just before a (re)start stays silent.
local handledIndex = nil

for _, name in ipairs(SLOTS) do
  noctalia.sound.load(name, "sounds/bell.ogg", function(ok, err)
    if ok then
      loaded[name] = true
    else
      noctalia.log(`wadokei: could not load the bell sound: {err}`)
    end
  end)
end

local function strike()
  slot = slot % #SLOTS + 1
  local name = SLOTS[slot]
  if loaded[name] then
    noctalia.sound.play(name)
  end
end

local function ring(count)
  strokesLeft = count
  nextStrokeAt = noctalia.nowMs()
end

local function strokesFor(r)
  local mode = noctalia.getConfig("bell") or "off"
  if mode == "count" then
    return r.strokes
  elseif mode == "once" then
    return 1
  end
  return 0
end

function update()
  local r = now.current()

  if r.sinceBell >= 0 and r.sinceBell < LATE_WINDOW and r.index ~= handledIndex then
    if handledIndex ~= nil then
      ring(strokesFor(r))
    end
    handledIndex = r.index
  elseif handledIndex == nil then
    handledIndex = false
  end

  local nowMs = noctalia.nowMs()
  if strokesLeft > 0 and nowMs >= nextStrokeAt then
    strike()
    strokesLeft -= 1
    nextStrokeAt = nowMs + STROKE_GAP_MS
  end

  -- Wake for the next stroke, else for the next quarter (every bell falls
  -- on one), and at least every minute to follow setting changes.
  local ms
  if strokesLeft > 0 then
    ms = math.max(nextStrokeAt - nowMs, 16)
  else
    ms = math.clamp(math.ceil(r.untilChange * 1000) + 50, 250, 60000)
  end
  noctalia.setUpdateInterval(ms)
end
