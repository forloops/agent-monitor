# Instructions for coding agents

This repo is a macOS menu bar app plus a Codex hook script. Read the README for
architecture; this file covers what you can't infer from the code.

## Installing for a user

Run `./install.sh`. It is idempotent — it builds the app, installs the hook to
`~/.agent-monitor/agent-status`, registers it in both agents' hook configs via
`hooks/register.py`, and (re)registers the LaunchAgent. Do not hand-roll
`launchctl`, edit the JSON configs, or copy files yourself.

Two steps are interactive and **cannot be automated — tell the user to do them**:

1. **Codex hook trust**: whenever `~/.agent-monitor/agent-status` is new or its
   content changed, Codex silently skips it until the user starts `codex`
   interactively and accepts the "Hooks need review" prompt (**Trust all and
   continue**). Never work around this with `--dangerously-bypass-hook-trust`
   in the user's config or shell profile; it exists only for throwaway
   verification runs.
2. **iTerm2 Python API** (iTerm2 users only): must be enabled (iTerm2 Settings →
   General → Magic → Enable Python API) or the iTerm2 source and exact session
   focusing fail and the menu shows "iTerm2 not reachable".
3. **Restart running agents**: hooks load at agent startup, so sessions that
   were already running when the hook was (re)installed don't report.

## Making changes

- Edit `hooks/agent-status` in the repo, never the installed copy in
  `~/.agent-monitor/` — then rerun `./install.sh` and warn the user that Codex
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
- Hook firing: `/tmp/agent-monitor-hook.log` gets a line per event; the
  records land in `~/.agent-monitor/sessions/`.
- Simulate a dot without an agent, from any terminal:
  `echo '{"hook_event_name":"PermissionRequest","session_id":"t"}' | ~/.agent-monitor/agent-status claude`
  — a yellow dot appears within ~2 s and lives as long as the shell that ran
  it (the hook records the nearest ancestor named like the agent, else its
  parent). Remove with the same command and `"SessionEnd"`.
- Inspect stored state: `cat ~/.agent-monitor/sessions/*.json`; the iTerm2
  source via `it2 session list` / `it2 session get-status -s <id>`.
