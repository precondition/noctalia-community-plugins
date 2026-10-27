--!nonstrict
-- Japanese traditional time (和時計): the twelve zodiac hours (十二刻).
--
-- Pure functions, no host globals, so the tests can run under the plain
-- `luau` CLI.
--
-- Every reading is a position `p` on a 12-unit dial that starts at the
-- beginning of 子の刻: koku `floor(p)`, quarter `floor(frac * 4) + 1`. Each
-- koku's bell (正刻) rings at `bellAt` into it, and 正子 / 正午 are the bells
-- of 子 and 午.
--
-- Fixed time (定時法): every koku is two clock hours, 子 = 23:00-01:00, and
-- the bell rings in the middle (bellAt = 0.5), so 正午 is 12:00, the start
-- of 午三つ. This is how the names are used today.
-- Temporal time (不定時法): 明け六つ is dawn and 暮れ六つ is dusk, the
-- daylight between them is cut into six equal koku and the night into six
-- more, so the hours stretch and shrink with the seasons. As in the Edo
-- period, each koku starts with its bell (bellAt = 0), so 明け六つ starts
-- 卯の刻 and 夜四つ starts 亥の刻.

local M = {}

M.ETO = { "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" }
M.ANIMALS = { "rat", "ox", "tiger", "rabbit", "dragon", "snake", "horse", "goat", "monkey", "rooster", "dog", "boar" }
M.BELLS = { "夜九つ", "夜八つ", "暁七つ", "明け六つ", "朝五つ", "昼四つ", "昼九つ", "昼八つ", "夕七つ", "暮れ六つ", "宵五つ", "夜四つ" }
M.QUARTERS = { "一つ", "二つ", "三つ", "四つ" }

-- How many times each koku's bell is struck: 九つ down to 四つ, twice a day.
M.BELL_STROKES = { 9, 8, 7, 6, 5, 4, 9, 8, 7, 6, 5, 4 }

-- Hiragana readings, in the same order. Quarters keep the old counting
-- (みつ, よつ), as in 丑三つ時 (うしみつどき).
M.ETO_KANA = { "ね", "うし", "とら", "う", "たつ", "み", "うま", "ひつじ", "さる", "とり", "いぬ", "い" }
M.BELLS_KANA = {
  "よるここのつ", "よるやつ", "あかつきななつ", "あけむつ", "あさいつつ", "ひるよつ",
  "ひるここのつ", "ひるやつ", "ゆうななつ", "くれむつ", "よいいつつ", "よるよつ",
}
M.QUARTERS_KANA = { "ひとつ", "ふたつ", "みつ", "よつ" }

-- Index (0-based) of the koku whose bell gets a name of its own.
M.SPECIALS = { [0] = "正子", [6] = "正午" }
M.SPECIALS_KANA = { [0] = "しょうし", [6] = "しょうご" }

-- How long after its bell a special name is shown, in seconds.
M.SPECIAL_WINDOW = 60

-- Sun altitude at Edo-period 明け六つ / 暮れ六つ: the sky is light enough to
-- see the lines of your palm. The 寛政暦 (1798) put it at 7°21'40" below the
-- horizon, about 35 minutes before sunrise in Japan.
M.TWILIGHT_ALTITUDE = -(7 + 21 / 60 + 40 / 3600)

-- Standard sunrise / sunset altitude (refraction plus the sun's radius).
M.HORIZON_ALTITUDE = -0.833

local function roundMs(seconds)
  return math.floor(seconds * 1000 + 0.5) / 1000
end

-- Builds a reading from a dial position, the number of seconds each koku
-- lasts at that position (only used to say when the reading next changes),
-- and how far into each koku its bell rings.
local function reading(p, secondsPerKoku, bellAt)
  p = p % 12
  local index = math.floor(p)
  local frac = p - index
  local quarter = math.min(math.floor(frac * 4) + 1, 4)
  local eto = M.ETO[index + 1]

  -- Seconds since this koku's bell, rounded to the millisecond so float
  -- noise cannot move a boundary.
  local sinceTrue = roundMs((frac - bellAt) * secondsPerKoku)
  local special, specialKana = nil, nil
  if M.SPECIALS[index] and sinceTrue >= 0 and sinceTrue < M.SPECIAL_WINDOW then
    special, specialKana = M.SPECIALS[index], M.SPECIALS_KANA[index]
  end

  -- Next boundary: the end of the special window, or the next quarter.
  local untilQuarter = roundMs((quarter / 4 - frac) * secondsPerKoku)
  local untilSpecial = M.SPECIALS[index] and -sinceTrue or nil
  if special then
    untilSpecial = M.SPECIAL_WINDOW - sinceTrue
  end
  local untilChange = untilQuarter
  if untilSpecial and untilSpecial > 0 and untilSpecial < untilChange then
    untilChange = untilSpecial
  end

  return {
    index = index,
    eto = eto,
    animal = M.ANIMALS[index + 1],
    koku = eto .. "の刻",
    kokuKana = M.ETO_KANA[index + 1] .. "のこく",
    quarter = quarter,
    quarterText = M.QUARTERS[quarter],
    quarterKana = M.QUARTERS_KANA[quarter],
    bell = M.BELLS[index + 1],
    bellKana = M.BELLS_KANA[index + 1],
    strokes = M.BELL_STROKES[index + 1],
    -- Seconds since this koku's bell rang; negative before it rings.
    sinceBell = sinceTrue,
    special = special,
    specialKana = specialKana,
    -- Daylight runs from the 明け六つ bell to the 暮れ六つ bell.
    isDay = p >= 3 + bellAt and p < 9 + bellAt,
    untilChange = untilChange,
  }
end

-- Fixed time from a local clock reading `{ hour, min, sec }`.
function M.fixed(clock)
  local seconds = clock.hour * 3600 + clock.min * 60 + (clock.sec or 0)
  -- 子の刻 starts at 23:00.
  local p = ((seconds + 3600) % 86400) / 7200
  local r = reading(p, 7200, 0.5)
  r.mode = "fixed"
  return r
end

local function rad(d)
  return d * math.pi / 180
end

local function deg(r)
  return r * 180 / math.pi
end

-- Unix times at which the sun crosses `altitude` (degrees) on the solar day
-- whose noon is nearest `nearEpoch`, at latitude `lat` / longitude `lon`
-- (degrees, east positive). Returns `rise, set`, or nil when the sun never
-- crosses that altitude (polar day or night). Accurate to about a minute.
--
-- This is the sunrise equation as used by NOAA's simplified calculator.
function M.sunTimes(nearEpoch, lat, lon, altitude)
  local julian = nearEpoch / 86400 + 2440587.5
  local n = math.floor(julian - 2451545.0 + 0.0008 + lon / 360 + 0.5)
  local meanSolarNoon = n - lon / 360
  local anomaly = (357.5291 + 0.98560028 * meanSolarNoon) % 360
  local m = rad(anomaly)
  local center = 1.9148 * math.sin(m) + 0.0200 * math.sin(2 * m) + 0.0003 * math.sin(3 * m)
  local lambda = rad((anomaly + center + 180 + 102.9372) % 360)
  local transit = 2451545.0 + meanSolarNoon + 0.0053 * math.sin(m) - 0.0069 * math.sin(2 * lambda)
  local sinDecl = math.sin(lambda) * math.sin(rad(23.4397))
  local cosDecl = math.cos(math.asin(sinDecl))
  local phi = rad(lat)
  local cosHour = (math.sin(rad(altitude)) - math.sin(phi) * sinDecl) / (math.cos(phi) * cosDecl)
  if cosHour < -1 or cosHour > 1 then
    return nil
  end
  local hourAngle = deg(math.acos(cosHour)) / 360
  local function toEpoch(j)
    return (j - 2440587.5) * 86400
  end
  return toEpoch(transit - hourAngle), toEpoch(transit + hourAngle)
end

-- Temporal time at Unix time `now` for `lat` / `lon`. `localNoon` is the Unix
-- time of local noon on today's date (the caller knows the timezone; this
-- module does not). Returns nil when there is no dawn or dusk to divide by.
function M.temporal(now, localNoon, lat, lon)
  local function edges(noon)
    return M.sunTimes(noon, lat, lon, M.TWILIGHT_ALTITUDE)
  end

  local dawn, dusk = edges(localNoon)
  if not dawn then
    return nil
  end

  local p, span, from, to
  if now >= dawn and now < dusk then
    from, to = dawn, dusk
    p = 3 + 6 * (now - dawn) / (dusk - dawn)
  elseif now >= dusk then
    -- The night runs from tonight's dusk to tomorrow's dawn.
    local nextDawn = edges(localNoon + 86400)
    if not nextDawn then
      return nil
    end
    from, to = dusk, nextDawn
    p = 9 + 6 * (now - dusk) / (nextDawn - dusk)
  else
    -- Before dawn, the night began at yesterday's dusk.
    local _, prevDusk = edges(localNoon - 86400)
    if not prevDusk then
      return nil
    end
    from, to = prevDusk, dawn
    p = 9 + 6 * (now - prevDusk) / (dawn - prevDusk)
  end
  span = (to - from) / 6

  local r = reading(p, span, 0)
  r.mode = "temporal"
  r.dawn = dawn
  r.dusk = dusk
  r.secondsPerKoku = span
  return r
end

-- Fills `{eto}`, `{koku}`, `{quarter}`, `{bell}` and `{animal}` in `format`.
-- `animalName` is the localized animal name; it defaults to the key.
function M.format(format, r, animalName)
  local values = {
    eto = r.eto,
    koku = r.koku,
    quarter = r.quarterText,
    bell = r.bell,
    animal = animalName or r.animal,
  }
  return (string.gsub(format, "{(%w+)}", function(key)
    return values[key]
  end))
end

return M
