# Instructions for coding agents

This repo is a macOS menu bar app plus a Codex hook script. Read the README for
architecture; this file covers what you can't infer from the code.

## Installing for a user

Run `./install.sh`. It is idempotent — it builds the app, installs the Codex
hook, and (re)registers the LaunchAgent. Do not hand-roll `launchctl` or copy
files yourself.

Two steps are interactive and **cannot be automated — tell the user to do them**:

1. **Codex hook trust**: whenever `~/.codex/hooks/codex-status` is new or its
   content changed, Codex silently skips it until the user starts `codex`
   interactively and accepts the "Hooks need review" prompt (**Trust all and
   continue**). Never work around this with `--dangerously-bypass-hook-trust`
   in the user's config or shell profile; it exists only for throwaway
   verification runs.
2. **iTerm2 Python API**: must be enabled (iTerm2 Settings → General → Magic →
   Enable Python API) or every `it2` call fails and the app reports
   "iTerm2 not reachable".

If `~/.codex/hooks.json` already existed, the installer leaves it alone — merge
the `codex-status` command into it for the events listed in the README.

## Making changes

- Edit `codex/codex-status` in the repo, never the installed copy in
  `~/.codex/hooks/` — then rerun `./install.sh` and warn the user that Codex
  will require one re-trust (step 1 above).
- After editing `AgentMonitor.swift`, rerun `./install.sh` (or
  `swiftc -O AgentMonitor.swift -o AgentMonitor.app/Contents/MacOS/AgentMonitor &&
  launchctl kickstart -k gui/$UID/com.forloops.agent-monitor`).
- The app must run from `AgentMonitor.app` (built by `install.sh`) for
  notifications to work; `UNUserNotificationCenter` needs a bundle identifier
  and the code no-ops without one. The bundle is gitignored; never commit it.
- Status transitions (notifications, elapsed time, hide-stopped, stall timer)
  are tracked in-app from poll to poll — iTerm2's status store has no
  timestamps. The only external activity signal is the session tty's mtime
  (updated on every terminal write), used for the "no output" stall check.

## Verifying

- App running: `pgrep -fl AgentMonitor`; launchd state:
  `launchctl print gui/$UID/com.forloops.agent-monitor`; app log:
  `/tmp/agent-monitor.log`.
- Codex hook firing: `/tmp/agent-monitor-codex.log` gets a line per event.
  Hooks resolve the iTerm2 session from `$ITERM_SESSION_ID`, so Codex must run
  inside iTerm2 — testing from another terminal proves nothing.
- Simulate a dot without an agent (from any iTerm2 session):
  `it2 session set-status --status waiting --detail test` — the dot should turn
  yellow within ~2 s. Real agent hooks overwrite it on their next event.
- Inspect stored state: `it2 session list` and
  `it2 session get-status -s <session-id>`.
