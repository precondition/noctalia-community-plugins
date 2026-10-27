# Wadokei

Shows the time in the bar the way the old Japanese zodiac clock (和時計) did:
丑の刻 三つ, 昼九つ, 正午. The day is divided into twelve 刻 named after the
zodiac animals, each split into four quarters. The hours can be fixed, or they
can stretch and shrink with the seasons as in the Edo period.

## Plugin

| Field | Value |
| --- | --- |
| ID | `precondition/wadokei` |
| Entries | Bar widget: `bar` |

## Usage

Add the **Wadokei** bar widget (`bar`) to a bar. It shows a sun by day and a
moon by night, followed by the current 刻 and quarter, for example `丑の刻 三つ`.
For the minute after noon and midnight it shows `正午` and `正子` instead.

Hover it for the 刻 and its animal, the quarter, the temple bell (時の鐘) for
that 刻, and the clock time. In seasonal mode the tooltip also shows today's
明け六つ and 暮れ六つ and how long each 刻 lasts right now.

| 刻 | Animal | Fixed hours | Bell |
| --- | --- | --- | --- |
| 子 | Rat | 23:00–01:00 | 夜九つ |
| 丑 | Ox | 01:00–03:00 | 夜八つ |
| 寅 | Tiger | 03:00–05:00 | 暁七つ |
| 卯 | Rabbit | 05:00–07:00 | 明け六つ |
| 辰 | Dragon | 07:00–09:00 | 朝五つ |
| 巳 | Snake | 09:00–11:00 | 昼四つ |
| 午 | Horse | 11:00–13:00 | 昼九つ |
| 未 | Goat | 13:00–15:00 | 昼八つ |
| 申 | Monkey | 15:00–17:00 | 夕七つ |
| 酉 | Rooster | 17:00–19:00 | 暮れ六つ |
| 戌 | Dog | 19:00–21:00 | 宵五つ |
| 亥 | Boar | 21:00–23:00 | 夜四つ |

Each 刻 has four 30-minute quarters, 一つ to 四つ, so 丑三つ時 is 02:00–02:30.
The bell rings at the middle of the 刻, the start of quarter three: 正午 is the
start of 午三つ and 正子 is the start of 子三つ.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `mode` | `select` | `fixed` | `fixed` (定時法): every 刻 is two clock hours. `temporal` (不定時法): 明け六つ is dawn and 暮れ六つ is dusk, and the daylight and the night are each split into six equal 刻. |
| `latitude` | `string` | empty | Degrees north for seasonal hours. Empty uses the shell's location. |
| `longitude` | `string` | empty | Degrees east for seasonal hours. Empty uses the shell's location. |
| `format` | `string` | `{koku} {quarter}` | Bar text. Tokens: `{koku}` 丑の刻, `{eto}` 丑, `{quarter}` 三つ, `{bell}` 夜八つ, `{animal}` the animal's name. `{eto}{quarter}` gives `丑三つ`. |
| `show_special` | `bool` | `true` | Show `正午` and `正子` for one minute at noon and midnight instead of the format. |
| `show_glyph` | `bool` | `true` | Show a sun by day and a moon by night. |

`format`, `show_special` and `show_glyph` are per bar widget; the rest apply to
the whole plugin.

## Notes

- In seasonal mode, 明け六つ and 暮れ六つ are not sunrise and sunset. Edo
  clocks set them when it was light enough to see the lines of your palm; the
  寛政暦 (1798) fixed this at the sun 7°21′40″ below the horizon, which is
  about half an hour before sunrise and after sunset. The plugin computes it
  locally from the coordinates, with no network access.
- Without `latitude` and `longitude`, the plugin reads the coordinates the
  shell has already resolved from `$XDG_CACHE_HOME/noctalia/location.json`
  (`~/.cache/noctalia/location.json`). Set a location under the shell's
  location settings, or fill in both plugin settings.
- With no location, or where the sun never gets that high or that low (polar
  day and night), seasonal mode falls back to fixed hours and the tooltip says
  so.
- The plugin writes no files and spawns no processes.
