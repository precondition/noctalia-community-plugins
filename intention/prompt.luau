--!nonstrict
-- Intention prompt - the full-screen panel that asks what you are about to do.
--
-- Keyboard flow: type the intention, press Enter. Tab moves to the duration and
-- network fields; every input submits on Enter. Captured chords:
--   ctrl+1/2/3   network: full / restricted / offline
--   alt+1..5     reuse a recent intention
--   ctrl+e       extend the current or expired session by 5 minutes
--   ctrl+q       done for now (runs the configured quit action)

local common = require("./lib/common.luau")

local PRESETS = { "15m", "25m", "45m", "1h", "2h" }

local session = noctalia.state.get("session") or { status = "none" }
local history = noctalia.state.get("history") or {}
local errorText = noctalia.state.get("error") or ""
local netBusy = noctalia.state.get("net.busy") == true
local appliedMode = noctalia.state.get("net.applied") or common.NET_FULL

local networkControl = noctalia.getConfig("network_control") ~= false
local defaultDuration = noctalia.getConfig("default_duration") or "25m"
local defaultNetwork = noctalia.getConfig("default_network") or common.NET_FULL

local goalText = ""
local durationText = defaultDuration
local netMode = common.NET_FULL
local allowlists = {}
local listIndex = 0
local domainsText = ""
local localError = ""

-- Bumping a key recreates that input, which reseeds its text and focuses it.
local goalKey = 0
local durationKey = 0
local domainsKey = 0
local focusTarget = "goal"
local isOpen = false
local goalExpanded = false

-- The card shows the goal on two lines until clicked. Labels cannot report
-- whether they were clipped, so estimate the width: wide (CJK) characters
-- count double. Two lines of the card hold roughly 110 narrow characters.
local COLLAPSED_LINES = 2
local COLLAPSE_UNITS = 100

local function goalIsLong(text)
  return common.textUnits(text) > COLLAPSE_UNITS
end

-- Recent goals share one row: each chip is cut to CHIP_UNITS, and chips stop
-- once the row's estimated width is used up. Alt+1..5 still reaches them all.
local CHIP_UNITS = 28
local CHIP_ROW_UNITS = 80
local CHIP_OVERHEAD_UNITS = 4

local function send(cmd)
  cmd.nonce = noctalia.nowMs()
  noctalia.state.set("cmd", cmd)
end

local function selectedList()
  if listIndex <= 0 then
    return ""
  end
  return allowlists[listIndex] or ""
end

local function resetForm()
  allowlists = common.listAllowlists()
  localError = ""
  local prev = session.net or {}
  if session.status == "expired" then
    goalText = session.goal or ""
  else
    goalText = ""
  end
  durationText = defaultDuration
  netMode = prev.mode or defaultNetwork
  if not networkControl then
    netMode = common.NET_FULL
  end
  domainsText = prev.domains or ""
  listIndex = 0
  for i, name in ipairs(allowlists) do
    if name == prev.list then
      listIndex = i
    end
  end
  focusTarget = "goal"
  goalKey += 1
  durationKey += 1
  domainsKey += 1
end

---- Actions ------------------------------------------------------------------

local function start()
  local goal = noctalia.string.trim(goalText)
  if goal == "" then
    localError = noctalia.tr("errors.goal_required")
    focusTarget = "goal"
    goalKey += 1
    render()
    return
  end
  local seconds = common.parseDuration(durationText)
  if not seconds then
    localError = noctalia.tr("errors.invalid_duration", { text = durationText })
    focusTarget = "duration"
    durationKey += 1
    render()
    return
  end
  if netMode == common.NET_RESTRICTED then
    local targets, invalid = common.resolveTargets({ mode = netMode, list = selectedList(), domains = domainsText })
    if #invalid > 0 then
      localError = noctalia.tr("errors.invalid_targets", { list = table.concat(invalid, ", ") })
      render()
      return
    end
    if #targets == 0 then
      localError = noctalia.tr("errors.empty_allowlist")
      render()
      return
    end
  end
  send({
    op = "start",
    goal = goal,
    durationSec = seconds,
    net = { mode = netMode, list = selectedList(), domains = domainsText },
  })
  panel.close()
end

local function setMode(mode)
  if not networkControl then
    return
  end
  netMode = mode
  if mode == common.NET_RESTRICTED then
    allowlists = common.listAllowlists()
  end
  render()
end

local function useRecent(index)
  local goal = history[index]
  if goal then
    goalText = goal
    focusTarget = "goal"
    goalKey += 1
    render()
  end
end

local function setPreset(text)
  durationText = text
  focusTarget = "goal"
  durationKey += 1
  goalKey += 1
  render()
end

local function extend(minutes)
  send({ op = "extend", minutes = minutes })
  panel.close()
end

local function finish()
  send({ op = "finish", quit = true })
end

---- Rendering ----------------------------------------------------------------

local function sectionLabel(text)
  return ui.label({ text = text, fontSize = 12, fontWeight = "bold", color = "on_surface_variant" })
end

local function goalLabel(goal)
  local label = ui.label({
    text = goal,
    fontSize = 18,
    fontWeight = "semibold",
    maxLines = goalExpanded and 100 or COLLAPSED_LINES,
    flexGrow = 1,
  })
  if not goalIsLong(goal) then
    return label
  end
  return ui.row({
    key = "card-goal",
    gap = 8,
    align = "start",
    tooltip = noctalia.tr(goalExpanded and "prompt.collapse" or "prompt.expand"),
    onClick = function()
      goalExpanded = not goalExpanded
      render()
    end,
  }, {
    label,
    ui.glyph({ name = goalExpanded and "chevron-up" or "chevron-down", size = 18, color = "on_surface_variant" }),
  })
end

local function sessionCard()
  local status = session.status
  if status ~= "active" and status ~= "expired" then
    return nil
  end

  local title
  local detail
  if status == "expired" then
    title = noctalia.tr("prompt.expired_title")
    detail = noctalia.tr("prompt.expired_detail", { time = common.formatShort(session.elapsedSec or 0) })
  else
    title = noctalia.tr("prompt.current_title")
    if (session.durationSec or 0) > 0 then
      detail = noctalia.tr("prompt.remaining", { time = common.formatTimer(session.remainingSec or 0, true) })
    else
      detail = noctalia.tr("prompt.elapsed", { time = common.formatTimer(session.elapsedSec or 0, false) })
    end
    if session.pausedBy then
      detail = detail .. " · " .. noctalia.tr("paused." .. session.pausedBy)
    end
  end

  local buttons = {
    ui.button({ text = noctalia.tr("prompt.extend", { minutes = 5 }), glyph = "plus", controlSize = "sm", onClick = function() extend(5) end }),
    ui.button({ text = noctalia.tr("prompt.extend", { minutes = 15 }), glyph = "plus", controlSize = "sm", onClick = function() extend(15) end }),
  }
  if status == "active" then
    table.insert(buttons, ui.button({
      text = session.pausedBy == "manual" and noctalia.tr("prompt.resume") or noctalia.tr("prompt.pause"),
      glyph = session.pausedBy == "manual" and "player-play" or "player-pause",
      controlSize = "sm",
      variant = "secondary",
      onClick = function() send({ op = "pause" }) end,
    }))
    table.insert(buttons, ui.button({
      text = noctalia.tr("prompt.end_early"),
      glyph = "player-stop",
      controlSize = "sm",
      variant = "outline",
      onClick = function() send({ op = "end" }) end,
    }))
  end

  return ui.column({
    gap = 8,
    padding = 14,
    radius = 12,
    fill = status == "expired" and "error/0.12" or "primary/0.10",
    border = status == "expired" and "error/0.5" or "primary/0.4",
    borderWidth = 1,
  }, {
    ui.label({ text = title, fontSize = 12, fontWeight = "bold", color = status == "expired" and "error" or "primary" }),
    goalLabel(session.goal or ""),
    ui.label({ text = detail, fontSize = 13, color = "on_surface_variant" }),
    ui.row({ gap = 8 }, buttons),
  })
end

local function networkSection()
  if not networkControl then
    return nil
  end

  local function modeButton(mode, glyph, labelKey, chord)
    return ui.button({
      key = "net-" .. mode,
      text = noctalia.tr(labelKey),
      glyph = glyph,
      selected = netMode == mode,
      variant = netMode == mode and "primary" or "outline",
      tooltip = chord,
      flexGrow = 1,
      onClick = function() setMode(mode) end,
    })
  end

  local children = {
    sectionLabel(noctalia.tr("prompt.network")),
    ui.row({ gap = 8 }, {
      modeButton(common.NET_FULL, "world", "network.full", "Ctrl+1"),
      modeButton(common.NET_RESTRICTED, "world-check", "network.restricted", "Ctrl+2"),
      modeButton(common.NET_OFFLINE, "world-off", "network.offline", "Ctrl+3"),
    }),
  }

  if netMode == common.NET_RESTRICTED then
    local options = { noctalia.tr("prompt.no_allowlist") }
    for _, name in ipairs(allowlists) do
      table.insert(options, name)
    end
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.select({
        key = "allowlist",
        options = options,
        selectedIndex = listIndex,
        flexGrow = 1,
        onChange = function(index)
          listIndex = tonumber(index) or 0
          render()
        end,
      }),
      ui.button({
        glyph = "folder-open",
        variant = "ghost",
        tooltip = noctalia.tr("prompt.open_allowlists"),
        onClick = function()
          local dir = common.allowlistDir()
          if dir then
            noctalia.runAsync({ "xdg-open", dir })
          end
        end,
      }),
    }))
    table.insert(children, ui.input({
      key = "domains-" .. domainsKey,
      value = domainsText,
      placeholder = noctalia.tr("prompt.domains_placeholder"),
      focus = focusTarget == "domains",
      onChange = function(value) domainsText = value end,
      onSubmit = function(value)
        domainsText = value
        start()
      end,
    }))
  end

  local note
  if netBusy then
    note = noctalia.tr("prompt.network_busy")
  elseif netMode ~= appliedMode then
    note = noctalia.tr("prompt.network_auth")
  else
    note = noctalia.tr("prompt.network_current", { mode = noctalia.tr("network." .. appliedMode) })
  end
  table.insert(children, ui.label({ text = note, fontSize = 11, color = "on_surface_variant" }))

  return ui.column({ gap = 8 }, children)
end

function render()
  if not isOpen then
    return
  end
  local message = localError ~= "" and localError or errorText
  local status = session.status

  local heading = status == "expired" and noctalia.tr("prompt.heading_next") or noctalia.tr("prompt.heading")

  local recent = {}
  local rowUnits = 0
  for i, goal in ipairs(history) do
    if i > 5 then
      break
    end
    local text = common.truncateUnits(goal, CHIP_UNITS)
    rowUnits += common.textUnits(text) + CHIP_OVERHEAD_UNITS
    if rowUnits > CHIP_ROW_UNITS and #recent > 0 then
      break
    end
    table.insert(recent, ui.button({
      key = "recent-" .. i,
      text = text,
      tooltip = text ~= goal and (goal .. " (Alt+" .. i .. ")") or ("Alt+" .. i),
      controlSize = "sm",
      variant = "ghost",
      onClick = function() useRecent(i) end,
    }))
  end

  local presets = {}
  for _, p in ipairs(PRESETS) do
    table.insert(presets, ui.button({
      key = "preset-" .. p,
      text = p,
      controlSize = "sm",
      variant = durationText == p and "primary" or "outline",
      onClick = function() setPreset(p) end,
    }))
  end
  table.insert(presets, ui.button({
    key = "preset-open",
    text = "∞",
    tooltip = noctalia.tr("prompt.open_ended"),
    controlSize = "sm",
    variant = (common.parseDuration(durationText) == 0) and "primary" or "outline",
    onClick = function() setPreset("") end,
  }))

  local body = {
    ui.row({ gap = 12, align = "center" }, {
      ui.glyph({ name = "target-arrow", size = 30, color = "primary" }),
      ui.label({ text = heading, fontSize = 26, fontWeight = "bold", flexGrow = 1 }),
    }),
  }

  local card = sessionCard()
  if card then
    table.insert(body, card)
  end

  if message ~= "" then
    table.insert(body, ui.row({ gap = 8, align = "center", padding = 10, radius = 8, fill = "error/0.15" }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
      ui.label({ text = message, color = "error", flexGrow = 1, maxLines = 4 }),
    }))
  end

  table.insert(body, ui.column({ gap = 8 }, {
    sectionLabel(noctalia.tr("prompt.goal")),
    ui.input({
      key = "goal-" .. goalKey,
      value = goalText,
      placeholder = noctalia.tr("prompt.goal_placeholder"),
      fontSize = 18,
      controlSize = "lg",
      focus = focusTarget == "goal",
      onChange = function(value) goalText = value end,
      onSubmit = function(value)
        goalText = value
        start()
      end,
    }),
  }))

  table.insert(body, ui.column({ gap = 8 }, {
    sectionLabel(noctalia.tr("prompt.duration")),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "duration-" .. durationKey,
        value = durationText,
        placeholder = noctalia.tr("prompt.duration_placeholder"),
        width = 160,
        focus = focusTarget == "duration",
        onChange = function(value) durationText = value end,
        onSubmit = function(value)
          durationText = value
          start()
        end,
      }),
      ui.row({ gap = 6, flexGrow = 1 }, presets),
    }),
  }))

  if #recent > 0 then
    table.insert(body, ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = noctalia.tr("prompt.recent"), fontSize = 11, color = "on_surface_variant" }),
      ui.row({ gap = 4, flexGrow = 1 }, recent),
    }))
  end

  local net = networkSection()
  if net then
    table.insert(body, net)
  end

  table.insert(body, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text = noctalia.tr("prompt.done." .. (noctalia.getConfig("quit_action") or "lock")),
      glyph = "logout",
      variant = "ghost",
      tooltip = "Ctrl+Q",
      onClick = finish,
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      text = status == "active" and noctalia.tr("prompt.switch") or noctalia.tr("prompt.start"),
      glyph = "arrow-right",
      variant = "primary",
      controlSize = "lg",
      enabled = not netBusy,
      onClick = start,
    }),
  }))

  table.insert(body, ui.label({
    text = noctalia.tr(networkControl and "prompt.hint" or "prompt.hint_no_network"),
    fontSize = 11,
    color = "on_surface_variant",
    textAlign = "center",
  }))

  panel.render(ui.row({ justify = "center", align = "center", padding = 24 }, {
    ui.column({ gap = 18, width = 640, padding = 28, radius = 16, fill = "surface_variant/0.35" }, body),
  }))
end

---- Lifecycle ----------------------------------------------------------------

function onOpen(_context)
  session = noctalia.state.get("session") or { status = "none" }
  history = noctalia.state.get("history") or {}
  errorText = noctalia.state.get("error") or ""
  noctalia.state.set("prompt.open", true)
  isOpen = true
  goalExpanded = false
  resetForm()
  render()
end

function onClose()
  isOpen = false
  noctalia.state.set("prompt.open", false)
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "ctrl+1" then
    setMode(common.NET_FULL)
  elseif chord == "ctrl+2" then
    setMode(common.NET_RESTRICTED)
  elseif chord == "ctrl+3" then
    setMode(common.NET_OFFLINE)
  elseif chord == "ctrl+e" then
    if session.status == "active" or session.status == "expired" then
      extend(5)
    end
  elseif chord == "ctrl+q" then
    finish()
  else
    local n = tonumber(string.match(chord, "^alt%+(%d)$"))
    if n then
      useRecent(n)
    end
  end
end

---- Live updates -------------------------------------------------------------

noctalia.state.watch("session", function(value)
  local previous = session.status
  session = value or { status = "none" }
  if previous ~= session.status and session.status == "expired" then
    resetForm()
  end
  render()
end)

noctalia.state.watch("history", function(value)
  history = value or {}
end)

noctalia.state.watch("error", function(value)
  errorText = value or ""
  render()
end)

noctalia.state.watch("net.busy", function(value)
  netBusy = value == true
  render()
end)

noctalia.state.watch("net.applied", function(value)
  appliedMode = value or common.NET_FULL
  render()
end)
