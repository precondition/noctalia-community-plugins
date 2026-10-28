--!nonstrict
-- Wadokei bar widget - the current time as a Japanese zodiac hour.
--
-- Shows e.g. 丑の刻 三つ, or 正午 / 正子 for the minute after them. In
-- temporal mode the hours follow dawn and dusk at the shell's location.

local wadokei = require("./lib/wadokei.luau")
local now = require("./lib/now.luau")

local lastTooltip = nil

local function hhmm(epoch)
  return os.date("%H:%M", math.floor(epoch + 0.5))
end

local function duration(seconds)
  local minutes = math.floor(seconds / 60 + 0.5)
  return noctalia.tr("tooltip.duration", { hours = minutes // 60, minutes = string.format("%02d", minutes % 60) })
end

local function render()
  local r = now.current()
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
  -- The tooltip clips long values, so the animal gets a row of its own.
  table.insert(rows, { noctalia.tr("tooltip.hour"), `{r.koku}（{r.kokuKana}）` })
  table.insert(rows, { noctalia.tr("tooltip.animal"), noctalia.tr("animal_tooltip." .. r.animal) })
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
