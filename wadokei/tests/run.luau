--!nonstrict
-- Test suite for lib/wadokei.luau. Run from the plugin directory:
--   luau tests/run.luau

local w = require("../lib/wadokei")

local failures = 0
local checks = 0

local function eq(actual, expected, label)
  checks += 1
  if actual ~= expected then
    failures += 1
    print(`FAIL  {label}: expected {tostring(expected)}, got {tostring(actual)}`)
  end
end

local function near(actual, expected, tolerance, label)
  checks += 1
  if actual == nil or math.abs(actual - expected) > tolerance then
    failures += 1
    print(`FAIL  {label}: expected {expected} ± {tolerance}, got {tostring(actual)}`)
  end
end

local function at(hour, min, sec)
  return w.fixed({ hour = hour, min = min, sec = sec or 0 })
end

local function name(r)
  return r.special or (r.eto .. r.quarterText)
end

-- Unix time of a UTC calendar moment (days-from-civil, no host timezone).
local function utc(y, mo, d, h, mi)
  if mo <= 2 then
    y -= 1
  end
  local era = y // 400
  local yoe = y - era * 400
  local mp = (mo + 9) % 12
  local doy = (153 * mp + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + h * 3600 + mi * 60
end

-- ---- Fixed time ----

eq(name(at(23, 0)), "子一つ", "23:00 starts 子の刻")
eq(at(23, 0).index, 0, "23:00 is koku 0")
eq(name(at(23, 59, 59)), "子二つ", "23:30 rolls to quarter two")
eq(name(at(0, 0)), "正子", "midnight is 正子")
eq(name(at(0, 1)), "子三つ", "正子 lasts one minute")
eq(name(at(0, 45)), "子四つ", "00:30 is 子四つ")
eq(name(at(1, 0)), "丑一つ", "01:00 starts 丑の刻")
eq(name(at(2, 0)), "丑三つ", "02:00 is 丑三つ")
eq(name(at(2, 29, 59)), "丑三つ", "丑三つ runs to 02:30")
eq(name(at(2, 30)), "丑四つ", "02:30 is 丑四つ")
eq(name(at(11, 59, 59)), "午二つ", "just before noon")
eq(name(at(12, 0)), "正午", "noon is 正午")
eq(name(at(12, 0, 59)), "正午", "正午 holds through its minute")
eq(name(at(12, 1)), "午三つ", "after 正午 comes 午三つ")
eq(at(12, 0).bell, "昼九つ", "noon bell")
eq(at(6, 0).bell, "明け六つ", "卯 is 明け六つ")
eq(at(18, 0).bell, "暮れ六つ", "酉 is 暮れ六つ")
eq(at(22, 59).koku, "亥の刻", "22:59 is still 亥")
eq(at(5, 59).isDay, false, "before 明け六つ is night")
eq(at(6, 0).isDay, true, "明け六つ starts the day")
eq(at(18, 0).isDay, false, "暮れ六つ starts the night")

-- Next change times.
eq(at(2, 10).untilChange, 20 * 60, "next quarter at 02:30")
eq(at(11, 50).untilChange, 10 * 60, "正午 arrives at 12:00")
eq(at(12, 0, 30).untilChange, 30, "正午 ends at 12:01")
eq(at(12, 5).untilChange, 25 * 60, "then the next quarter")

eq(at(2, 0).kokuKana, "うしのこく", "koku reading")
eq(at(2, 0).quarterKana, "みつ", "quarter reading")
eq(at(2, 0).bellKana, "よるやつ", "bell reading")
eq(at(18, 0).bellKana, "くれむつ", "暮れ六つ reading")
eq(at(12, 0).specialKana, "しょうご", "正午 reading")
eq(at(12, 1).specialKana, nil, "no special reading after 正午")
for i = 1, 12 do
  eq(w.ETO_KANA[i] ~= nil and w.BELLS_KANA[i] ~= nil, true, `reading for koku {i}`)
end

eq(w.format("{koku} {quarter} ({bell}, {animal})", at(2, 0), "Ox"), "丑の刻 三つ (夜八つ, Ox)", "format tokens")
eq(w.format("{eto}{nope}", at(2, 0)), "丑{nope}", "unknown tokens stay")

-- ---- Sun times ----

-- Charleroi, 2026-10-27 (CET, UTC+1). The shell's weather cache, from
-- Open-Meteo, says sunrise 07:24 and sunset 17:27 local.
local lat, lon = 50.41136, 4.44448
local noon = utc(2026, 10, 27, 11, 0)
local rise, set = w.sunTimes(noon, lat, lon, w.HORIZON_ALTITUDE)
near(rise, utc(2026, 10, 27, 6, 24), 120, "Charleroi sunrise")
near(set, utc(2026, 10, 27, 16, 27), 120, "Charleroi sunset")

-- Twilight comes before sunrise and after sunset.
local dawn, dusk = w.sunTimes(noon, lat, lon, w.TWILIGHT_ALTITUDE)
eq(dawn < rise and dusk > set, true, "twilight brackets the sun")

-- Polar night: not even twilight in Svalbard mid-December.
eq(w.sunTimes(utc(2026, 12, 21, 11, 0), 80, 18, w.TWILIGHT_ALTITUDE), nil, "polar night")

-- ---- Temporal time ----

local t = w.temporal(dawn, noon, lat, lon)
eq(t.bell, "明け六つ", "dawn is 明け六つ")
eq(t.eto, "卯", "dawn is 卯の刻")
eq(t.quarter, 1, "dawn starts 卯の刻")
eq(t.isDay, true, "dawn starts the day")

local mid = w.temporal((dawn + dusk) / 2 + 1, noon, lat, lon)
eq(mid.special, "正午", "halfway through the day is 正午")
eq(mid.eto .. mid.quarterText, "午一つ", "正午 starts 午の刻")

t = w.temporal(dusk, noon, lat, lon)
eq(t.bell, "暮れ六つ", "dusk is 暮れ六つ")
eq(t.eto, "酉", "dusk starts 酉の刻")
eq(t.isDay, false, "dusk starts the night")

-- Two night koku after 暮れ六つ comes 夜四つ, the start of 亥の刻.
local yotsu = w.temporal(dusk + 2 * t.secondsPerKoku + 1, noon, lat, lon)
eq(yotsu.bell, "夜四つ", "two koku after dusk is 夜四つ")
eq(yotsu.eto .. yotsu.quarterText, "亥一つ", "夜四つ starts 亥の刻")

-- Before dawn, the night is measured from yesterday's dusk.
local _, prevDusk = w.sunTimes(noon - 86400, lat, lon, w.TWILIGHT_ALTITUDE)
local midnight = w.temporal((prevDusk + dawn) / 2 + 1, noon, lat, lon)
eq(midnight.special, "正子", "halfway through last night is 正子")
eq(midnight.eto .. midnight.quarterText, "子一つ", "正子 starts 子の刻")
local early = w.temporal(dawn - 60, noon, lat, lon)
eq(early.eto, "寅", "a minute before dawn is still 寅")
eq(early.quarter, 4, "in its last quarter")

-- After dusk, the night runs to tomorrow's dawn.
local nextDawn = w.sunTimes(noon + 86400, lat, lon, w.TWILIGHT_ALTITUDE)
local late = w.temporal((dusk + nextDawn) / 2 + 1, noon, lat, lon)
eq(late.special, "正子", "halfway through tonight is 正子")

-- Autumn nights in Belgium are long, so night koku outlast day koku.
eq(late.secondsPerKoku > mid.secondsPerKoku, true, "night koku are longer in autumn")

eq(w.temporal(utc(2026, 12, 21, 11, 0), utc(2026, 12, 21, 11, 0), 80, 18), nil, "temporal falls back in polar night")

if failures == 0 then
  print(`PASS  {checks} checks`)
else
  print(`\n{failures} failure(s) out of {checks} checks`)
  error("test suite failed", 0)
end
