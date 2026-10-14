--!nonstrict
-- Intention bar widget - keeps the stated intention in view.
--
-- Shows the goal and, optionally, the countdown (or elapsed time for an
-- open-ended session). Click to open the prompt; right-click to pause.

local common = require("./lib/common.luau")

local session = noctalia.state.get("session") or { status = "none" }
local appliedMode = noctalia.state.get("net.applied") or common.NET_FULL

local function truncate(text, maxChars)
  if maxChars <= 0 or utf8.len(text) == nil or utf8.len(text) <= maxChars then
    return text
  end
  local cut = utf8.offset(text, maxChars) or #text
  return string.sub(text, 1, cut - 1) .. "…"
end

local lastTooltip = nil

local function timeText()
  if (session.durationSec or 0) > 0 then
    return common.formatTimer(session.remainingSec or 0, true)
  end
  return "+" .. common.formatTimer(session.elapsedSec or 0, false)
end

local NET_GLYPHS = {
  [common.NET_RESTRICTED] = "world-check",
  [common.NET_OFFLINE] = "world-off",
}

local function render()
  local showGoal = noctalia.getConfig("show_goal") ~= false
  local showTimer = noctalia.getConfig("show_timer") ~= false
  local showNetwork = noctalia.getConfig("show_network") ~= false
  local maxChars = noctalia.getConfig("max_length") or 40
  local vertical = barWidget.isVertical()
  local status = session.status

  local glyph = "target-arrow"
  local color = nil
  local parts = {}
  local goalShown = false

  if status == "active" then
    if session.pausedBy then
      glyph = "player-pause"
      color = "on_surface_variant"
    end
    if showGoal and not vertical then
      -- The table tooltip clips each value to one short line, so the goal
      -- carries its own plain tooltip, which wraps and shows it in full.
      local goal = session.goal or ""
      table.insert(parts, ui.row({ key = "goal", tooltip = goal }, {
        ui.label({ text = truncate(goal, maxChars), color = color }),
      }))
      goalShown = true
    end
    if showTimer and not vertical then
      local low = (session.durationSec or 0) > 0 and (session.remainingSec or 0) <= 60
      table.insert(parts, ui.label({
        text = timeText(),
        fontWeight = "bold",
        color = low and "error" or (color or "primary"),
      }))
    end
  elseif status == "expired" then
    glyph = "alarm"
    color = "error"
    if not vertical then
      table.insert(parts, ui.label({ text = noctalia.tr("bar.expired"), color = "error", fontWeight = "bold" }))
    end
  else
    color = "on_surface_variant"
    if not vertical then
      table.insert(parts, ui.label({ text = noctalia.tr("bar.none"), color = color }))
    end
  end

  local children = { ui.glyph({ name = glyph, color = color }) }
  for _, p in ipairs(parts) do
    table.insert(children, p)
  end
  if showNetwork and NET_GLYPHS[appliedMode] then
    table.insert(children, ui.glyph({ name = NET_GLYPHS[appliedMode], color = "on_surface_variant" }))
  end

  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))

  local rows = {}
  if status == "active" or status == "expired" then
    if not goalShown then
      table.insert(rows, { noctalia.tr("tooltip.goal"), session.goal or "" })
    end
    if (session.durationSec or 0) > 0 then
      table.insert(rows, { noctalia.tr("tooltip.remaining"), common.formatTimer(session.remainingSec or 0, true) })
    end
    table.insert(rows, { noctalia.tr("tooltip.elapsed"), common.formatTimer(session.elapsedSec or 0, false) })
    if session.pausedBy then
      table.insert(rows, { noctalia.tr("tooltip.status"), noctalia.tr("paused." .. session.pausedBy) })
    end
  else
    table.insert(rows, { noctalia.tr("tooltip.status"), noctalia.tr("bar.none") })
  end
  table.insert(rows, { noctalia.tr("tooltip.network"), noctalia.tr("network." .. appliedMode) })
  local encoded = noctalia.json.encode(rows)
  if encoded ~= lastTooltip then
    lastTooltip = encoded
    barWidget.setTooltip(rows)
  end
end

function update()
  render()
end

function onClick()
  noctalia.togglePanel(common.PROMPT_ID)
end

function onRightClick()
  if session.status == "active" then
    noctalia.state.set("cmd", { op = "pause", nonce = noctalia.nowMs() })
  end
end

noctalia.state.watch("session", function(value)
  session = value or { status = "none" }
  render()
end)

noctalia.state.watch("net.applied", function(value)
  appliedMode = value or common.NET_FULL
  render()
end)
