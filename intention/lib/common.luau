--!nonstrict
-- Helpers shared by the service, the prompt panel, and the bar widget.

local M = {}

M.PLUGIN_ID = "precondition/intention"
M.PROMPT_ID = "precondition/intention:prompt"

M.NET_FULL = "full"
M.NET_RESTRICTED = "restricted"
M.NET_OFFLINE = "offline"

-- "25", "25m", "1h", "1h30", "1h30m", "90s", "1:30" -> seconds.
-- Empty or "0" -> 0 (open-ended). nil when the text cannot be parsed.
function M.parseDuration(text)
  local s = string.lower(noctalia.string.trim(text or ""))
  if s == "" or s == "0" or s == "-" or s == "∞" then
    return 0
  end

  local h, m = string.match(s, "^(%d+):(%d%d?)$")
  if h then
    return tonumber(h) * 3600 + tonumber(m) * 60
  end

  if string.match(s, "^%d+%.?%d*$") then
    return math.floor(tonumber(s) * 60)
  end

  local total = 0
  local rest = string.gsub(s, "%s", "")
  local matched = false
  for num, unit in string.gmatch(rest, "(%d+%.?%d*)([hms]?)") do
    matched = true
    local n = tonumber(num) or 0
    if unit == "h" then
      total += n * 3600
    elseif unit == "s" then
      total += n
    else
      total += n * 60
    end
  end
  -- Reject anything with characters outside digits, dots, and h/m/s.
  if not matched or string.match(rest, "[^%d%.hms]") then
    return nil
  end
  return math.floor(total)
end

-- East Asian wide and fullwidth characters, plus emoji.
local WIDE_RANGES = {
  { 0x1100, 0x115F }, -- Hangul Jamo
  { 0x2E80, 0x303E }, -- CJK radicals, symbols and punctuation
  { 0x3041, 0x33FF }, -- kana, CJK compatibility
  { 0x3400, 0x4DBF }, -- CJK extension A
  { 0x4E00, 0x9FFF }, -- CJK unified ideographs
  { 0xA000, 0xA4CF }, -- Yi
  { 0xAC00, 0xD7A3 }, -- Hangul syllables
  { 0xF900, 0xFAFF }, -- CJK compatibility ideographs
  { 0xFE30, 0xFE4F }, -- CJK compatibility forms
  { 0xFF00, 0xFF60 }, -- fullwidth forms
  { 0xFFE0, 0xFFE6 }, -- fullwidth signs
  { 0x1F300, 0x1FAFF }, -- emoji
  { 0x20000, 0x3FFFD }, -- CJK extensions B and later
}

local function charUnits(code)
  for _, r in ipairs(WIDE_RANGES) do
    if code >= r[1] and code <= r[2] then
      return 2
    end
  end
  return 1
end

-- Rough display width of text in "narrow character" units: wide characters
-- count double. Labels cannot report their rendered width, so layout
-- decisions use this estimate.
function M.textUnits(text)
  local units = 0
  for _, code in utf8.codes(text) do
    units += charUnits(code)
  end
  return units
end

-- Cuts text to at most maxUnits (see textUnits), ending with "…".
function M.truncateUnits(text, maxUnits)
  if M.textUnits(text) <= maxUnits then
    return text
  end
  local out = {}
  local units = 1 -- room for the ellipsis
  for _, code in utf8.codes(text) do
    local w = charUnits(code)
    if units + w > maxUnits then
      break
    end
    units += w
    table.insert(out, utf8.char(code))
  end
  return table.concat(out) .. "…"
end

function M.formatClock(seconds)
  seconds = math.max(0, math.floor(seconds))
  local h = seconds // 3600
  local m = (seconds % 3600) // 60
  local s = seconds % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

-- Live time display, following the time_format and show_seconds settings:
--   natural  1h 51m   (with seconds: 1h 51m 20s)
--   clock    1:51     (with seconds: 1:51:20)
-- Without seconds, a countdown rounds up to the minute so it never reads
-- "0m" with time left; elapsed time rounds down.
function M.formatTimer(seconds, countdown)
  local clock = noctalia.getConfig("time_format") == "clock"
  seconds = math.max(0, math.floor(seconds))
  if noctalia.getConfig("show_seconds") == true then
    return clock and M.formatClock(seconds) or M.formatNatural(seconds)
  end
  local minutes = countdown and math.ceil(seconds / 60) or seconds // 60
  if clock then
    return string.format("%d:%02d", minutes // 60, minutes % 60)
  end
  if minutes == 0 then
    return noctalia.tr("time.minutes", { m = 0 })
  end
  return M.formatShort(minutes * 60)
end

-- Human duration down to the second: "1h 51m 20s", "4m 5s", "30s".
function M.formatNatural(seconds)
  seconds = math.max(0, math.floor(seconds))
  local h = seconds // 3600
  local m = (seconds % 3600) // 60
  local s = seconds % 60
  if s == 0 and seconds > 0 then
    return M.formatShort(seconds)
  elseif h > 0 then
    return noctalia.tr("time.hours_minutes_seconds", { h = h, m = m, s = s })
  elseif m > 0 then
    return noctalia.tr("time.minutes_seconds", { m = m, s = s })
  end
  return noctalia.tr("time.seconds", { s = s })
end

-- Compact human duration for labels: "25m", "1h 30m", "45s".
function M.formatShort(seconds)
  seconds = math.max(0, math.floor(seconds))
  local h = seconds // 3600
  local m = (seconds % 3600) // 60
  if h > 0 and m > 0 then
    return noctalia.tr("time.hours_minutes", { h = h, m = m })
  elseif h > 0 then
    return noctalia.tr("time.hours", { h = h })
  elseif m > 0 then
    return noctalia.tr("time.minutes", { m = m })
  end
  return noctalia.tr("time.seconds", { s = seconds })
end

-- Hostnames (example.com, sub.example.co.uk), IPv4 addresses with an optional
-- prefix, and IPv6 addresses with an optional prefix. The helper script repeats
-- this check because it runs as root.
function M.isValidTarget(entry)
  if #entry == 0 or #entry > 253 then
    return false
  end
  if string.match(entry, "^%d+%.%d+%.%d+%.%d+$") or string.match(entry, "^%d+%.%d+%.%d+%.%d+/%d+$") then
    return true
  end
  if string.find(entry, ":", 1, true) then
    return string.match(entry, "^[%x:]+$") ~= nil or string.match(entry, "^[%x:]+/%d+$") ~= nil
  end
  for label in string.gmatch(entry, "[^%.]+") do
    if #label > 63 or not string.match(label, "^[%w]$") and not string.match(label, "^[%w][%w%-]*[%w]$") then
      return false
    end
  end
  return string.match(entry, "%.") ~= nil
    and string.match(entry, "^[%w%.%-]+$") ~= nil
    and string.match(entry, "%.%.") == nil
    and string.sub(entry, 1, 1) ~= "."
    and string.sub(entry, -1) ~= "."
end

-- Splits free text (commas, spaces, newlines) into valid, lowercased, unique
-- targets. Accepts pasted URLs and strips the scheme and path. Returns the valid
-- list and the rejected entries.
function M.parseTargets(text, into, seen)
  local valid = into or {}
  local invalid = {}
  seen = seen or {}
  for line in string.gmatch((text or "") .. "\n", "([^\n]*)\n") do
    line = string.gsub(line, "#.*$", "")
    for raw in string.gmatch(line, "[^%s,;]+") do
      local entry = string.lower(raw)
      entry = string.gsub(entry, "^%a[%w+.-]*://", "")
      -- Drop a URL path, but keep a CIDR prefix such as 10.0.0.0/8.
      if not string.match(entry, "^[%x%.:]+/%d+$") then
        entry = string.gsub(entry, "[/?#].*$", "")
      end
      entry = string.gsub(entry, "^%*%.", "")
      if entry ~= "" then
        if M.isValidTarget(entry) then
          if not seen[entry] then
            seen[entry] = true
            table.insert(valid, entry)
          end
        else
          table.insert(invalid, raw)
        end
      end
    end
  end
  return valid, invalid
end

function M.allowlistDir()
  local configured = noctalia.getConfig("allowlist_dir")
  if type(configured) == "string" and noctalia.string.trim(configured) ~= "" then
    return noctalia.expandPath(noctalia.string.trim(configured))
  end
  local base = noctalia.pluginDataDir()
  if not base then
    return nil
  end
  return base .. "/allowlists"
end

-- Allowlist names (file names without ".txt"), sorted.
function M.listAllowlists()
  local dir = M.allowlistDir()
  if not dir then
    return {}
  end
  local files = noctalia.listDir(dir) or {}
  local names = {}
  for _, file in ipairs(files) do
    local name = string.match(file, "^(.+)%.txt$")
    if name then
      table.insert(names, name)
    end
  end
  table.sort(names)
  return names
end

-- Resolves a network choice into the sorted target list the helper receives.
function M.resolveTargets(net)
  if not net or net.mode ~= M.NET_RESTRICTED then
    return {}, {}
  end
  local seen = {}
  local valid = {}
  local invalid = {}
  local function add(text)
    local _, bad = M.parseTargets(text, valid, seen)
    for _, b in ipairs(bad) do
      table.insert(invalid, b)
    end
  end
  local dir = M.allowlistDir()
  if dir and net.list and net.list ~= "" and not string.find(net.list, "/", 1, true) then
    add(noctalia.readFile(dir .. "/" .. net.list .. ".txt") or "")
  end
  add(net.domains or "")
  table.sort(valid)
  return valid, invalid
end

function M.netSignature(mode, targets)
  if mode == M.NET_RESTRICTED then
    return mode .. ":" .. table.concat(targets, ",")
  end
  return mode
end

return M
