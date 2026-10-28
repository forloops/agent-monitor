# Agent Monitor

macOS menu bar app showing one colored dot per active coding agent — **Claude Code**
and **Codex CLI** sessions in any terminal (iTerm2, Terminal.app, Ghostty, kitty,
WezTerm, Warp, VS Code, …).

![Menu bar showing an agent status dot](screenshot.png)

- 🟢 **green** — working
- 🟡 **yellow** — attention needed (permission prompt / waiting on you)
- 🔴 **red** — stopped (turn done, idle, interrupted, or error)
- 🟠 **orange** — stalled (see below)
- ○ gray hollow — no active agent sessions

Each agent gets its own shape so you can tell them apart in the bar:
**●** Claude Code, **◆** Codex, **■** anything else (switchable to all-circles
in Settings).

Click the dots for a dropdown listing each agent (`project · claude — working  4m`,
`project · codex — waiting  12s`, …) with how long it has been in that state.
Clicking an agent brings its terminal forward and, where the terminal offers a
way, selects the exact pane: iTerm2 sessions, Terminal.app tabs, kitty windows
(needs `allow_remote_control`), WezTerm panes, and tmux panes. While the menu is
open, keys `1`–`9` pick a row.

- **Notifications**: a macOS notification when an agent needs attention or
  finishes a turn (each togglable in Settings). Clicking it focuses the session.
  macOS asks once for notification permission on first launch.
- **Global shortcut** `⌃⌥A`: focuses the next agent waiting on you, cycling
  through them; with none waiting, cycles through all agents. Can be disabled
  in Settings.
- **Hide stopped sessions**: Settings can age stopped (red) sessions out of
  the bar after 1–60 minutes; the dropdown shows how many are hidden.
- **Stall detection**: a working agent turns orange, and you get a
  notification, when either its terminal has printed nothing for 90 s (both
  agents animate a spinner during a turn, so silence means the process is
  wedged — detected via the tty's modification time) or the turn has run for
  longer than a configurable limit (default 15 min, off/5–60 in Settings).
  The dropdown says which: `— stalled (no output for 2m)` or
  `— stalled (working for 22m)`.

Dot colors are customizable: **Settings…** in the dropdown opens a window with a
color well per state (working / attention needed / stopped / stalled) and a reset button.
Changes apply immediately and persist across restarts (stored in `UserDefaults`;
inspect with `defaults read AgentMonitor`, wipe with `defaults delete AgentMonitor`).

## How it works

Both agents run `hooks/agent-status` (installed to `~/.agent-monitor/`) from
their lifecycle hooks. On each event it writes one JSON record per agent
session to `~/.agent-monitor/sessions/`, and the app reads that directory
every 2 seconds:

```
Claude Code ── hooks in ~/.claude/settings.json ──┐
                                                  ├──▶ ~/.agent-monitor/sessions/*.json ──▶ AgentMonitor
Codex CLI ──── hooks in ~/.codex/hooks.json ──────┘        (one file per session)          (menu bar)
```

A record holds the status, working directory, the agent's PID and tty, and the
terminal's identity (`__CFBundleIdentifier`, `ITERM_SESSION_ID`, `TMUX_PANE`,
`KITTY_WINDOW_ID`, `WEZTERM_PANE`, …) so the app can focus it later. A record
is live while its PID is running; `SessionEnd` deletes it and the app prunes
records whose process is gone.

iTerm2 is also read as a second source (`it2 session list` / `get-status`),
which picks up Claude Code sessions that only have iTerm2's own `cc-status`
hook, and the Codex hook still pushes status into iTerm2's store so iTerm2's
UI shows Codex too. Sessions reported by both sources are shown once.

### Status mapping

| Agent event                                     | status    | Dot |
|-------------------------------------------------|-----------|-----|
| prompt submitted, tool ran, compaction          | `working` | 🟢  |
| permission requested, elicitation               | `waiting` | 🟡  |
| turn finished                                   | `done`    | 🔴  |
| session start, interrupted, idle prompt         | `idle`    | 🔴  |
| failure                                         | `error`   | 🔴  |

The status→state mapping lives in `DotState(status:)` at the top of
`AgentMonitor.swift`; the event→status tables for each agent are at the top of
`hooks/agent-status`.

## Requirements

- macOS with Xcode Command Line Tools (`swiftc`)
- Claude Code and/or Codex CLI with lifecycle hooks support
- Optional: iTerm2 with its Python API enabled (Settings → General → Magic →
  Enable Python API) for exact session focusing and for the iTerm2 status
  source

Verified against iTerm2 3.7.6, Codex CLI 0.160.0, and Claude Code as of
October 2026.

## Install

```sh
./install.sh
```

This builds `AgentMonitor.app`, installs the hook to `~/.agent-monitor/agent-status`,
registers it in `~/.claude/settings.json` and `~/.codex/hooks.json` (existing
entries are preserved; a one-time `.bak` of each file is kept), and registers a
LaunchAgent so the app starts at login. Already-running agent sessions pick up
the hook when restarted.

### Codex one-time trust step

Codex only runs lifecycle hooks it trusts (they execute outside its sandbox).
After installing or changing the hook, start `codex` interactively once — it
shows a **"Hooks need review"** prompt — and choose **Trust all and continue**
(also manageable later via `/hooks` in the TUI). Until then Codex silently
skips the hook and no Codex dots appear.

## Maintenance

```sh
./install.sh                                                   # rebuild + restart after changes
launchctl kickstart -k gui/$UID/com.forloops.agent-monitor     # just restart
./uninstall.sh                                                 # stop + remove
```

## Troubleshooting

- **No notifications**: System Settings → Notifications → Agent Monitor must be
  allowed, and the app must be running from `AgentMonitor.app` (rerun
  `./install.sh`; `/tmp/agent-monitor.log` says "not running from an app bundle"
  otherwise).
- **No dots at all** (not even ○): check `/tmp/agent-monitor.log` and that the
  LaunchAgent is loaded: `launchctl print gui/$UID/com.forloops.agent-monitor`.
- **"iTerm2 not reachable" while iTerm2 is running**: enable iTerm2's Python API
  (Settings → General → Magic → Enable Python API) and approve the connection if
  iTerm2 prompts for it.
- **A session shows no dot**: `/tmp/agent-monitor-hook.log` gets a line per
  hook event. Nothing there while the agent runs means the hook isn't
  registered (check `~/.claude/settings.json` / `~/.codex/hooks.json` for
  `agent-status`) or, for Codex, isn't trusted yet (see the trust step above).
  Sessions started before `./install.sh` need a restart to load the hook.
- **Inspect stored state directly**: `cat ~/.agent-monitor/sessions/*.json`.
- **Clicking a row doesn't select the pane**: the app only activates the
  terminal app unless it knows the pane — iTerm2 needs its Python API, kitty
  needs `allow_remote_control yes`, Terminal.app needs the Automation permission
  macOS prompts for on first use.

## Project layout

```
AgentMonitor.swift    # the menu bar app (single file, no dependencies)
AgentMonitor.app/     # built by install.sh (gitignored)
hooks/agent-status    # Claude Code + Codex lifecycle hook -> ~/.agent-monitor/sessions/
hooks/register.py     # merges/removes the hook in both agents' hook configs
install.sh            # build + install hook, register it, LaunchAgent
uninstall.sh          # remove LaunchAgent, hook registrations, ~/.agent-monitor
```

## Limitations

- Pane-level focusing is per-terminal; unsupported terminals just get their
  app activated.
- Status granularity is whatever the hooks report; there's no heartbeat beyond
  hook events, so a crashed agent process is caught by the foreground-job check
  rather than a timeout.
- Codex lifecycle hooks are a new and still-evolving Codex feature (event names,
  payloads, and the trust flow were verified against Codex CLI 0.160.0); expect
  the integration to need occasional updates as Codex changes.
