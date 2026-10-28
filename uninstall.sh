#!/bin/bash
# Remove the AgentMonitor LaunchAgent and the Codex hook.
set -uo pipefail

LABEL="com.forloops.agent-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Stopped AgentMonitor."
rm -f "$PLIST" && echo "Removed LaunchAgent plist."
rm -f "$HOME/.codex/hooks/codex-status" && echo "Removed Codex hook script."

echo
echo "Left in place (remove manually if you no longer want them):"
echo "  ~/.codex/hooks.json          (Codex hook registration)"
echo "  ~/.claude/settings.json      (iTerm2 cc-status hooks for Claude Code)"
