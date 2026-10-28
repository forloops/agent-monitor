#!/bin/bash
# Build AgentMonitor, install the Codex hook, and set up the LaunchAgent.
# Idempotent: safe to re-run after pulling changes (it rebuilds and restarts).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.forloops.agent-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CODEX_HOOK="$HOME/.codex/hooks/codex-status"

APP="$REPO_DIR/AgentMonitor.app"
BIN="$APP/Contents/MacOS/AgentMonitor"

echo "==> Building AgentMonitor.app"
# A real bundle (with a bundle identifier) is required for macOS notifications;
# a bare binary runs fine but can't post them.
mkdir -p "$APP/Contents/MacOS"
swiftc -O "$REPO_DIR/AgentMonitor.swift" -o "$BIN"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$LABEL</string>
    <key>CFBundleName</key>
    <string>Agent Monitor</string>
    <key>CFBundleExecutable</key>
    <string>AgentMonitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
# Ad-hoc signature so macOS keeps a stable identity for the notification permission.
codesign --force --sign - "$APP" 2>/dev/null || echo "    (codesign unavailable; continuing unsigned)"
rm -f "$REPO_DIR/AgentMonitor"   # pre-bundle binary from older installs

HOOK_DIR="$HOME/.agent-monitor"
HOOK="$HOOK_DIR/agent-status"

echo "==> Installing agent hook"
mkdir -p "$HOOK_DIR/sessions"
if ! cmp -s "$REPO_DIR/hooks/agent-status" "$HOOK" 2>/dev/null; then
    cp "$REPO_DIR/hooks/agent-status" "$HOOK"
    chmod +x "$HOOK"
    echo "    Hook script changed: start 'codex' once and accept the hooks review"
    echo "    (Trust all and continue), or Codex will silently skip it."
else
    echo "    Hook script unchanged."
fi
rm -f "$HOME/.codex/hooks/codex-status"   # pre-unified hook from older installs
python3 "$REPO_DIR/hooks/register.py" install "$HOOK"

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
        <string>$BIN</string>
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
echo "    macOS will ask once whether Agent Monitor may send notifications — allow it."
