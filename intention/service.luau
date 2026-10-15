--!nonstrict
-- Intention service - owns the session, the countdown, and the network gate.
--
-- The prompt panel and the bar widget are thin clients: they read the
-- published "session" table and send commands through "cmd".
--
-- State published to the other entries (noctalia.state):
--   session         { status, goal, durationSec, remainingSec, elapsedSec, net, pausedBy }
--                   status: "none" | "active" | "expired"
--   net.applied     the network mode currently enforced by the helper
--   net.busy        true while waiting on pkexec
--   history         recent goals, newest first
--   error           last error message to show in the prompt, or ""
--
-- IPC: noctalia msg plugin precondition/intention:service all <event> [payload]

local common = require("./lib/common.luau")

noctalia.setUpdateInterval(1000)

local DATA_DIR = noctalia.pluginDataDir()
local SESSION_FILE = DATA_DIR and (DATA_DIR .. "/session.json")
local LOG_FILE = DATA_DIR and (DATA_DIR .. "/log.jsonl")
local MAX_HISTORY = 8
local MAX_LOG_LINES = 1000
-- A gap longer than this between ticks means the machine slept; that time is
-- not counted.
local SLEEP_GAP_MS = 60 * 1000
-- Away for longer than this (suspended, shell not running, rebooted), a session
-- is over: the next start asks for a fresh intention instead of resuming.
local STALE_MS = 30 * 60 * 1000

local cfg = {}

local function readConfig()
  cfg.enforce = noctalia.getConfig("enforce") ~= false
  cfg.promptOnStartup = noctalia.getConfig("prompt_on_startup") ~= false
  cfg.reopenDelay = math.max(1, noctalia.getConfig("reopen_delay_seconds") or 5)
  cfg.pauseWhenIdle = noctalia.getConfig("pause_when_idle") ~= false
  cfg.pauseWhenLocked = noctalia.getConfig("pause_when_locked") ~= false
  cfg.warnMinutes = noctalia.getConfig("warn_minutes") or 2
  cfg.networkControl = noctalia.getConfig("network_control") ~= false
  cfg.resetNetworkOnDone = noctalia.getConfig("reset_network_on_done") ~= false
  cfg.quitAction = noctalia.getConfig("quit_action") or "lock"
  cfg.keepLog = noctalia.getConfig("keep_log") ~= false
  cfg.helperPath = noctalia.string.trim(noctalia.getConfig("helper_path") or "")
end
readConfig()

local function bootId()
  return noctalia.string.trim(noctalia.readFile("/proc/sys/kernel/random/boot_id") or "")
end

---- Persistent state ---------------------------------------------------------

local data = {
  status = "none",
  goal = "",
  durationMs = 0,
  remainingMs = 0,
  elapsedMs = 0,
  startedAt = 0,
  net = { mode = common.NET_FULL, list = "", domains = "" },
  applied = { mode = common.NET_FULL, signature = common.NET_FULL, bootId = "" },
  history = {},
  enforceSuspended = false,
  warned = false,
  bootId = "",
  savedAt = 0,
}

local function load()
  if not SESSION_FILE then
    return
  end
  local raw = noctalia.readFile(SESSION_FILE)
  if not raw then
    return
  end
  local saved = noctalia.json.decode(raw)
  if type(saved) ~= "table" then
    return
  end
  for k, v in pairs(saved) do
    data[k] = v
  end
  -- nftables rules do not survive a reboot.
  if data.applied.bootId ~= bootId() then
    data.applied = { mode = common.NET_FULL, signature = common.NET_FULL, bootId = bootId() }
  end
end


local function save()
  if not SESSION_FILE then
    return
  end
  data.bootId = bootId()
  data.savedAt = os.time()
  noctalia.writeFile(SESSION_FILE, noctalia.json.encode(data, true))
end

local function appendLog(outcome)
  if not cfg.keepLog or not LOG_FILE or data.goal == "" then
    return
  end
  local entry = noctalia.json.encode({
    goal = data.goal,
    startedAt = data.startedAt,
    endedAt = os.time(),
    plannedSec = math.floor(data.durationMs / 1000),
    focusedSec = math.floor(data.elapsedMs / 1000),
    network = data.net.mode,
    outcome = outcome,
  })
  local existing = noctalia.readFile(LOG_FILE) or ""
  local lines = {}
  for line in string.gmatch(existing, "[^\n]+") do
    table.insert(lines, line)
  end
  table.insert(lines, entry)
  while #lines > MAX_LOG_LINES do
    table.remove(lines, 1)
  end
  noctalia.writeFile(LOG_FILE, table.concat(lines, "\n") .. "\n")
end

-- Called after load(): a session from an earlier boot, or one left alone for
-- long, is not resumed.
local function dropStaleSession()
  if data.status == "none" then
    return
  end
  local stale = data.bootId ~= bootId() or (os.time() - (data.savedAt or 0)) * 1000 > STALE_MS
  if stale then
    appendLog("interrupted")
    data.status = "none"
    data.goal = ""
    data.durationMs = 0
    data.remainingMs = 0
    data.elapsedMs = 0
  end
end

local function seedAllowlists()
  local dir = common.allowlistDir()
  if not dir then
    return
  end
  if noctalia.fileExists(dir) then
    return
  end
  noctalia.mkdirAll(dir)
  noctalia.writeFile(dir .. "/example.txt", table.concat({
    "# One domain, IP address, or CIDR range per line. Lines starting with # are ignored.",
    "# Subdomains are not matched automatically: list each host you need.",
    "# Rename or copy this file; every *.txt file in this folder becomes an allowlist.",
    "docs.noctalia.dev",
    "github.com",
    "codeload.github.com",
    "raw.githubusercontent.com",
    "",
  }, "\n"))
end

---- Runtime state -------------------------------------------------------------

local idle = false
local locked = false
local manualPause = false
local promptOpen = noctalia.state.get("prompt.open") == true
local netBusy = false
local lastTick = noctalia.nowMs()
local lastPromptAttempt = 0
local startupAt = noctalia.nowMs()
local lockPollCounter = 0
local saveCounter = 0
local lastError = ""
local pendingStartupPrompt = false

local function pausedBy()
  if manualPause then
    return "manual"
  elseif cfg.pauseWhenLocked and locked then
    return "locked"
  elseif cfg.pauseWhenIdle and idle then
    return "idle"
  end
  return nil
end

-- Watchers fire on every set, even when the value is unchanged, so only
-- publish keys whose encoded value differs from what was last sent.
local published = {}

local function publishKey(key, value)
  local encoded = noctalia.json.encode(value)
  if published[key] == encoded then
    return
  end
  published[key] = encoded
  noctalia.state.set(key, value)
end

local function publish()
  publishKey("session", {
    status = data.status,
    goal = data.goal,
    durationSec = math.floor(data.durationMs / 1000),
    remainingSec = math.ceil(data.remainingMs / 1000),
    elapsedSec = math.floor(data.elapsedMs / 1000),
    net = data.net,
    pausedBy = data.status == "active" and pausedBy() or nil,
  })
  publishKey("net.applied", data.applied.mode)
  publishKey("net.busy", netBusy)
  publishKey("history", data.history)
  publishKey("error", lastError)
  publishKey("enforce", cfg.enforce and not data.enforceSuspended)
end

local function setError(message)
  lastError = message or ""
  publishKey("error", lastError)
end

local function openPrompt()
  lastPromptAttempt = noctalia.nowMs()
  noctalia.runAsync({ "noctalia", "msg", "panel-open", common.PROMPT_ID })
end

local function closePrompt()
  noctalia.runAsync({ "noctalia", "msg", "panel-close", common.PROMPT_ID })
end

local function rememberGoal(goal)
  local history = { goal }
  for _, g in ipairs(data.history) do
    if g ~= goal and #history < MAX_HISTORY then
      table.insert(history, g)
    end
  end
  data.history = history
end

---- Network ------------------------------------------------------------------

local function helperPath()
  if cfg.helperPath ~= "" then
    return noctalia.expandPath(cfg.helperPath)
  end
  return (noctalia.pluginDir() or ".") .. "/bin/intention-net"
end

-- Applies a network mode through pkexec, then calls done(ok). Skips the
-- password prompt entirely when the requested rules are already in place.
local function applyNetwork(net, done)
  if not cfg.networkControl then
    done(true)
    return
  end
  local targets, invalid = common.resolveTargets(net)
  if #invalid > 0 then
    done(false, noctalia.tr("errors.invalid_targets", { list = table.concat(invalid, ", ") }))
    return
  end
  if net.mode == common.NET_RESTRICTED and #targets == 0 then
    done(false, noctalia.tr("errors.empty_allowlist"))
    return
  end
  local signature = common.netSignature(net.mode, targets)
  if signature == data.applied.signature then
    done(true)
    return
  end
  if not noctalia.commandExists("pkexec") then
    done(false, noctalia.tr("errors.no_pkexec"))
    return
  end

  -- The polkit dialog must not end up underneath the overlay prompt.
  netBusy = true
  publishKey("net.busy", true)
  closePrompt()

  -- The helper is run through /bin/sh so it works even when the exported
  -- plugin copy lost its executable bit.
  local argv = { "pkexec", "/bin/sh", helperPath(), net.mode }
  for _, t in ipairs(targets) do
    table.insert(argv, t)
  end
  noctalia.runAsync(argv, function(result)
    netBusy = false
    if result.exitCode == 0 then
      data.applied = { mode = net.mode, signature = signature, bootId = bootId() }
      save()
      publish()
      done(true)
    else
      local reason = noctalia.string.trim(result.stderr or "")
      if result.exitCode == 126 or result.exitCode == 127 then
        reason = noctalia.tr("errors.auth_cancelled")
      end
      noctalia.log(`network helper failed ({result.exitCode}): {result.stderr}`)
      publish()
      done(false, noctalia.tr("errors.network_failed", { reason = reason }))
    end
  end, 120000)
end

---- Session transitions ------------------------------------------------------

local function startSession(goal, durationSec, net)
  goal = noctalia.string.trim(goal or "")
  if goal == "" then
    setError(noctalia.tr("errors.goal_required"))
    openPrompt()
    return
  end
  net = net or { mode = common.NET_FULL, list = "", domains = "" }
  if not cfg.networkControl then
    net = { mode = common.NET_FULL, list = "", domains = "" }
  end

  applyNetwork(net, function(ok, err)
    if not ok then
      setError(err)
      openPrompt()
      return
    end
    if data.status == "active" then
      appendLog("switched")
    elseif data.status == "expired" then
      appendLog("completed")
    end
    data.status = "active"
    data.goal = goal
    data.durationMs = durationSec * 1000
    data.remainingMs = durationSec * 1000
    data.elapsedMs = 0
    data.startedAt = os.time()
    data.net = net
    data.warned = false
    manualPause = false
    rememberGoal(goal)
    setError("")
    save()
    publish()
    if promptOpen then
      closePrompt()
    end
  end)
end

local function expire()
  data.status = "expired"
  data.remainingMs = 0
  save()
  publish()
  noctalia.notify(noctalia.tr("notify.expired_title"), noctalia.tr("notify.expired_body", { goal = data.goal }))
  openPrompt()
end

local function extend(minutes)
  local ms = math.floor((minutes or 5) * 60 * 1000)
  if ms <= 0 then
    return
  end
  if data.status == "expired" then
    data.status = "active"
    data.remainingMs = 0
  elseif data.status ~= "active" then
    return
  end
  if data.durationMs == 0 then
    -- Turning an open-ended session into a timed one.
    data.durationMs = data.elapsedMs
  end
  data.durationMs += ms
  data.remainingMs += ms
  data.warned = false
  setError("")
  save()
  publish()
  if promptOpen then
    closePrompt()
  end
end

local QUIT_COMMANDS = {
  lock = { "noctalia", "msg", "session", "lock" },
  suspend = { "noctalia", "msg", "session", "lock-and-suspend" },
  logout = { "noctalia", "msg", "session", "logout" },
  shutdown = { "noctalia", "msg", "session", "shutdown" },
}

-- Ends the session for the day: logs it, optionally restores full network
-- access, then runs the configured quit action.
local function finish(runQuitAction)
  if data.status ~= "none" then
    appendLog(data.status == "expired" and "completed" or "ended_early")
  end
  data.status = "none"
  data.goal = ""
  data.durationMs = 0
  data.remainingMs = 0
  data.elapsedMs = 0
  manualPause = false
  setError("")
  save()
  publish()

  local action = runQuitAction and cfg.quitAction or "none"
  local function quit()
    local cmd = QUIT_COMMANDS[action]
    if cmd then
      noctalia.runAsync(cmd)
    end
  end

  -- Shutting down clears the rules anyway, so skip the password prompt.
  local needsReset = cfg.resetNetworkOnDone and data.applied.mode ~= common.NET_FULL and action ~= "shutdown"
  if needsReset then
    applyNetwork({ mode = common.NET_FULL }, function(ok, err)
      if not ok then
        noctalia.notifyError(noctalia.tr("notify.title"), err)
      end
      quit()
    end)
  else
    if promptOpen and action ~= "none" then
      closePrompt()
    end
    quit()
  end
end

-- Ends the current session early and goes back to the prompt.
local function endEarly()
  if data.status ~= "none" then
    appendLog("ended_early")
  end
  data.status = "none"
  data.goal = ""
  data.durationMs = 0
  data.remainingMs = 0
  data.elapsedMs = 0
  manualPause = false
  save()
  publish()
  openPrompt()
end

local function enforcing()
  return cfg.enforce and not data.enforceSuspended
end

---- Commands from the panel and widget ---------------------------------------

noctalia.state.watch("cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.op == "start" then
    startSession(cmd.goal, tonumber(cmd.durationSec) or 0, cmd.net)
  elseif cmd.op == "extend" then
    extend(tonumber(cmd.minutes) or 5)
  elseif cmd.op == "finish" then
    finish(cmd.quit == true)
  elseif cmd.op == "pause" then
    manualPause = not manualPause
    publish()
  elseif cmd.op == "end" then
    endEarly()
  end
end)

noctalia.state.watch("prompt.open", function(open)
  promptOpen = open == true
  if not promptOpen then
    lastPromptAttempt = noctalia.nowMs()
  end
end)

---- Lock detection -----------------------------------------------------------

-- Noctalia sets logind's LockedHint while its lock screen is up, so polling it
-- works without any configuration. The locked/unlocked IPC events below are an
-- alternative for setups where that hint is not maintained.
local sessionId = noctalia.getenv("XDG_SESSION_ID")

local function pollLock()
  if not sessionId or sessionId == "" or not noctalia.commandExists("loginctl") then
    return
  end
  noctalia.runAsync({ "loginctl", "show-session", sessionId, "-p", "LockedHint", "--value" }, function(result)
    if result.exitCode == 0 then
      local value = noctalia.string.trim(result.stdout or "") == "yes"
      if value ~= locked then
        locked = value
        publish()
      end
    end
  end)
end

---- Tick ---------------------------------------------------------------------

function update()
  local now = noctalia.nowMs()
  local dt = now - lastTick
  lastTick = now

  lockPollCounter += 1
  if lockPollCounter >= 3 then
    lockPollCounter = 0
    pollLock()
  end

  if data.status == "active" and dt > STALE_MS then
    -- Back after a long suspend: the old intention no longer applies.
    expire()
    return
  end

  if data.status == "active" then
    local away = dt > SLEEP_GAP_MS
    if not pausedBy() and not away and dt > 0 then
      data.elapsedMs += dt
      if data.durationMs > 0 then
        data.remainingMs -= dt
        if data.remainingMs <= 0 then
          expire()
          return
        end
        local warnMs = cfg.warnMinutes * 60 * 1000
        if warnMs > 0 and not data.warned and data.remainingMs <= warnMs and data.durationMs > warnMs then
          data.warned = true
          noctalia.notify(
            noctalia.tr("notify.warn_title"),
            noctalia.tr("notify.warn_body", { goal = data.goal, time = common.formatShort(math.ceil(data.remainingMs / 60000) * 60) })
          )
        end
      end
    end
    saveCounter += 1
    if saveCounter >= 15 then
      saveCounter = 0
      save()
    end
    publish()
    return
  end

  -- Ask once shortly after startup; the shell's IPC may not be ready right away.
  if pendingStartupPrompt and now - startupAt >= 3000 then
    pendingStartupPrompt = false
    if not promptOpen and not locked then
      openPrompt()
    end
    return
  end

  -- No active session: keep the prompt on screen while enforcing.
  if not enforcing() or promptOpen or netBusy or locked then
    return
  end
  if now - lastPromptAttempt >= cfg.reopenDelay * 1000 then
    openPrompt()
  end
end

function onConfigChanged()
  readConfig()
  publish()
end

-- Disabling or uninstalling the plugin must not leave the network restricted
-- with nothing left to lift it. The command uses no plugin files, so it still
-- works when they are being removed. Shutdown is skipped: a password prompt
-- there would be unwelcome, and the rules do not survive a reboot.
function onExit(_signal, reason)
  if (reason == "disable" or reason == "uninstall") and data.applied.mode ~= common.NET_FULL then
    data.applied.signature = "unknown"
    save()
    noctalia.runAsync({ "pkexec", "/usr/bin/nft", "delete", "table", "inet", "intention" })
  end
end

---- IPC ----------------------------------------------------------------------

-- start <minutes> <goal...>   start a session with full network access (0 = open-ended)
-- extend [minutes]            add time to the current or just-expired session (default 5)
-- done                        end the session and run the quit action
-- end                         end the session early and return to the prompt
-- pause                       pause or resume the countdown manually
-- prompt                      open the prompt
-- idle | active               idle notifications (for [idle.behavior] hooks)
-- locked | unlocked           lock notifications (for [hooks] session_locked/unlocked)
-- enforce on|off              temporarily stop or resume reopening the prompt
function onIpc(event, payload)
  payload = noctalia.string.trim(payload or "")
  if event == "start" then
    local minutes, goal = string.match(payload, "^(%S+)%s+(.+)$")
    local seconds = minutes and common.parseDuration(minutes)
    if seconds and goal then
      startSession(goal, seconds, { mode = common.NET_FULL, list = "", domains = "" })
    else
      noctalia.log("usage: start <minutes> <goal>")
    end
  elseif event == "extend" then
    extend(tonumber(payload) or 5)
  elseif event == "done" then
    finish(true)
  elseif event == "end" then
    endEarly()
  elseif event == "pause" then
    manualPause = not manualPause
    publish()
  elseif event == "prompt" then
    openPrompt()
  elseif event == "idle" or event == "active" then
    idle = event == "idle"
    publish()
  elseif event == "locked" or event == "unlocked" then
    locked = event == "locked"
    publish()
  elseif event == "enforce" then
    data.enforceSuspended = payload == "off"
    save()
    publish()
    if payload == "off" and promptOpen and data.status ~= "active" then
      closePrompt()
    end
  end
end

---- Startup ------------------------------------------------------------------

load()
dropStaleSession()
seedAllowlists()
pendingStartupPrompt = data.status ~= "active" and (cfg.promptOnStartup or data.status == "expired")
lastPromptAttempt = startupAt
save()
publish()
