#!/bin/bash
# Build AgentMonitor, install the Codex hook, and set up the LaunchAgent.
# Idempotent: safe to re-run after pulling changes (it rebuilds and restarts).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.forloops.agent-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CODEX_HOOK="$HOME/.codex/hooks/codex-status"

echo "==> Building AgentMonitor"
swiftc -O "$REPO_DIR/AgentMonitor.swift" -o "$REPO_DIR/AgentMonitor"

echo "==> Installing Codex hook"
mkdir -p "$HOME/.codex/hooks"
if ! cmp -s "$REPO_DIR/codex/codex-status" "$CODEX_HOOK" 2>/dev/null; then
    cp "$REPO_DIR/codex/codex-status" "$CODEX_HOOK"
    chmod +x "$CODEX_HOOK"
    echo "    Hook script changed: start 'codex' once and accept the hooks review"
    echo "    (Trust all and continue), or Codex will silently skip it."
else
    echo "    Hook script unchanged."
fi

if [ ! -f "$HOME/.codex/hooks.json" ]; then
    cat > "$HOME/.codex/hooks.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "$CODEX_HOOK", "timeout": 10 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "$CODEX_HOOK", "timeout": 10 }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "$CODEX_HOOK", "timeout": 10 }] }
    ],
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "$CODEX_HOOK", "timeout": 10 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$CODEX_HOOK", "timeout": 10 }] }
    ],
    "Interrupt": [
      { "hooks": [{ "type": "command", "command": "$CODEX_HOOK", "timeout": 10 }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "$CODEX_HOOK", "timeout": 10 }] }
    ]
  }
}
EOF
    echo "    Wrote ~/.codex/hooks.json"
else
    echo "    ~/.codex/hooks.json already exists; left untouched."
fi

echo "==> Installing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$REPO_DIR/AgentMonitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/agent-monitor.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/agent-monitor.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "==> Done. Look for the dots in your menu bar."
