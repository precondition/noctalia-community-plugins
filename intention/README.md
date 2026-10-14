# Intention

Mindful computer use. Before you start, say what you are about to do and for how long. Your intention stays in the bar
until the time is up, and then you are asked again: continue, do something else, or call it a day. You can also limit
internet access for the session: full access, only an allowlist of domains, or none at all.

## Plugin

| Field | Value |
| --- | --- |
| ID | `precondition/intention` |
| Entries | Bar widget: `bar`; panel: `prompt`; service: `service` |

## Requirements

- Noctalia 5.2.0 or newer (plugin API 32).
- `pkexec` (polkit) with a running polkit authentication agent, to change network access.
- `nftables` (the `nft` command), which enforces the network modes.

`pkexec` and `nftables` are only used when **Control internet access** is on. Turn it off to use the plugin purely as an intention timer.

## Usage

1. Enable the plugin. Shortly after the shell starts, the **prompt** fills the screen and asks what you intend to do.
2. Type your intention, then press `Enter`. The prefilled default duration is used. Press `Tab` to
   reach the duration and network fields; `Enter` in any field starts the session.
3. Add the **Intention** bar widget (`precondition/intention:bar`) to see the goal and countdown. Click it to reopen the
   prompt (extend, pause, end early, or switch to something else); right-click it to pause or resume.
4. When the time is up you get a notification and the prompt comes back. Extend by 5 or 15 minutes, state the next
   intention, or choose **Done for now**, which ends the session and runs the configured quit action (lock the screen by
   default).

While no intention is set, dismissing the prompt with `Escape` only hides it for a few seconds (see
**Insist on an intention**). Noctalia always lets Escape close a panel, so this is a gentle nudge, not a lock.

Open or toggle the prompt yourself, for example from a compositor keybind:

```sh
noctalia msg panel-toggle precondition/intention:prompt
```

### Keyboard shortcuts in the prompt

| Keys | Action |
| --- | --- |
| `Enter` | Start the session (from any field) |
| `Tab` / `Shift+Tab` | Move between fields and buttons |
| `Ctrl+1` / `Ctrl+2` / `Ctrl+3` | Internet access: full / restricted / offline |
| `Alt+1` … `Alt+5` | Reuse one of the recent intentions |
| `Ctrl+E` | Extend the current or expired session by 5 minutes |
| `Ctrl+Q` | Done for now |
| `Escape` | Hide the prompt |

Durations accept `25` (minutes), `25m`, `1h`, `1h30`, `1:30`, `90s`, or nothing / `∞` for no time limit.

### Internet access

- **Full access**: no restrictions.
- **Restricted**: only the domains from the selected allowlist plus any domains typed inline are reachable. DNS stays
  open so names keep resolving.
- **Offline**: all outgoing traffic is blocked, except loopback.

Only traffic from your own user is filtered; system services such as package updates keep working. Changing the mode
asks for your password through pkexec. Starting a new session with the same mode and the same domains does not ask
again, and an expired session keeps its rules until you choose what is next.

Allowlists are plain text files, one domain, IP address, or CIDR range per line, `#` for comments. Every `*.txt` file in
the allowlist folder appears in the prompt's drop-down. The folder defaults to
`~/.local/state/noctalia/plugins/data/precondition/intention/allowlists/` and is seeded with an `example.txt`. The
folder button next to the drop-down opens it.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enforce` | `bool` | `true` | Reopen the prompt whenever it is dismissed while no intention is set. |
| `reopen_delay_seconds` | `int` | `5` | Seconds before the dismissed prompt comes back. |
| `prompt_on_startup` | `bool` | `true` | Ask for an intention when the shell starts. |
| `default_duration` | `string` | `25m` | Duration prefilled in the prompt; empty means no time limit. |
| `quit_action` | `select` | `lock` | What **Done for now** does: `lock`, `suspend` (lock and suspend), `logout`, `shutdown`, or `none`. |
| `pause_when_idle` | `bool` | `true` | Stop the countdown while idle. Needs the idle hook below. |
| `pause_when_locked` | `bool` | `true` | Stop the countdown while the screen is locked. |
| `warn_minutes` | `int` | `2` | Notify this many minutes before the time is up; `0` disables it. |
| `time_format` | `select` | `natural` | How remaining and elapsed time are written: `natural` (`1h 51m`) or `clock` (`1:51`). |
| `show_seconds` | `bool` | `false` | Show remaining and elapsed time to the second in the bar, its tooltip, and the prompt. Off shows whole minutes. |
| `keep_log` | `bool` | `true` | Append each finished session to `log.jsonl` in the plugin's data folder. |
| `network_control` | `bool` | `true` | Offer the internet access modes. |
| `default_network` | `select` | `full` | Mode preselected when there is no previous session. |
| `reset_network_on_done` | `bool` | `true` | Restore full access on **Done for now** (skipped for shut down, which clears the rules anyway). |
| `allowlist_dir` | `folder` | empty | Allowlist folder; empty uses the plugin's data folder. |
| `helper_path` | `file` | empty | Network helper run through pkexec; empty uses the bundled `bin/intention-net`. |

Bar widget settings: `show_goal`, `show_timer` (countdown, or elapsed time without a limit; see `show_seconds`), `show_network` (an icon
while access is restricted or off), and `max_length` (truncate the goal; `0` shows it in full).

### Pausing when idle or locked

Lock detection works out of the box: the service reads logind's `LockedHint`, which Noctalia sets while its lock
screen is up. Time spent suspended is never counted.

Idle time needs one idle behavior in your Noctalia config, because plugins cannot observe idle state directly:

```toml
[idle.behavior.intention]
timeout = 120
action = "command"
command = "noctalia msg plugin precondition/intention:service all idle"
resume_command = "noctalia msg plugin precondition/intention:service all active"
```

Noctalia's `[idle] pre_action_fade_seconds` applies to every idle behavior, including this one: when it is above 0,
the screen briefly dims at the timeout before the plugin is told you are idle. Moving the pointer cancels it and the
countdown keeps running.

If you use another locker, report it with hooks:

```toml
[hooks]
session_locked = "noctalia msg plugin precondition/intention:service all locked"
session_unlocked = "noctalia msg plugin precondition/intention:service all unlocked"
```

## IPC

```sh
noctalia msg plugin precondition/intention:service all <event> [payload]
```

| Event | Payload | Effect |
| --- | --- | --- |
| `start` | `<duration> <goal>` | Start a session with full access, e.g. `start 45m Review pull requests`. Duration `0` means no limit. |
| `extend` | `[minutes]` | Add time to the current or just-expired session (default 5). |
| `pause` | | Pause or resume the countdown. |
| `end` | | End the session early and return to the prompt. |
| `done` | | End the session and run the quit action. |
| `prompt` | | Open the prompt. |
| `idle` / `active` | | Report idle state (see above). |
| `locked` / `unlocked` | | Report lock state (see above). |
| `enforce` | `off` / `on` | Temporarily stop or resume reopening the prompt, without changing settings. |

## Notes

- **Files written**: `session.json` (current session, so it survives restarts), `log.jsonl` (session log, capped at
  1000 entries), and the allowlist folder, all under `~/.local/state/noctalia/plugins/data/precondition/intention/`.
- **Processes spawned**: `noctalia msg panel-open|panel-close|session …` to show the prompt and run the quit action,
  `loginctl show-session` every few seconds to read the lock state, `xdg-open` for the allowlist folder button, and
  `pkexec /bin/sh <helper> <mode> [targets…]` to change network access.
- **The network helper** (`bin/intention-net`) runs as root. It validates every target, resolves domains (and their
  `www.` variant) once with `getent`, then atomically replaces a single nftables table, `inet intention`, that filters
  only your user's outgoing traffic. Run it with `--dry-run` to print the ruleset without applying it:
  `sh bin/intention-net --dry-run restricted github.com`.
- **Safer helper setup**: by default pkexec runs the helper from the plugin folder, which your user can write to. To
  remove that, copy it to a root-owned location and point **Network helper path** at it:
  `sudo install -m 755 bin/intention-net /usr/local/bin/intention-net`.
- **Limits of restricted mode**: addresses are resolved when the session starts. Sites behind CDNs that rotate
  addresses, or that load assets from other domains, may partly break; add those domains to the list. Subdomains
  are not included automatically.
- **Recovery**: the rules live only in memory and disappear on reboot. To remove them immediately:
  `sudo nft delete table inet intention`.
- The prompt is shown on the focused monitor only.
