#!/bin/bash
# Remove the AgentMonitor LaunchAgent and the Codex hook.
set -uo pipefail

LABEL="com.forloops.agent-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Stopped AgentMonitor."
rm -f "$PLIST" && echo "Removed LaunchAgent plist."
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$REPO_DIR/hooks/register.py" remove "$HOME/.agent-monitor/agent-status"
rm -f "$HOME/.codex/hooks/codex-status"
rm -rf "$HOME/.agent-monitor" && echo "Removed ~/.agent-monitor (hook + session store)."

echo
echo "Left in place: iTerm2's own cc-status entries in Claude's settings.json files."
