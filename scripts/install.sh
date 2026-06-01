#!/bin/bash
#
# install.sh — build, install, and start touchutil on macOS.
#
# Safe to run multiple times — stops any running instance, replaces the app
# bundle, and reloads the agent automatically.
#
# Any extra arguments are passed through to touchutil in the LaunchAgent,
# e.g.:  ./scripts/install.sh --display-index 1
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
APP_SRC="$REPO_ROOT/build/touchutil.app"
APP_DST="/Applications/touchutil.app"
EXEC="$APP_DST/Contents/MacOS/touchutil"
CLI_LINK="$PREFIX/bin/touchutil"
LABEL="com.touchutil.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# 1. Stop any existing running instance cleanly before replacing files.
echo "==> Stopping any existing touchutil instance..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
pkill -x touchutil 2>/dev/null || true

# 2. Build if needed.
if [ ! -d "$APP_SRC" ]; then
    echo "==> Building..."
    "$REPO_ROOT/scripts/build-universal.sh"
fi

# 3. Install the app bundle (sudo). Removes old copy first to avoid conflicts.
echo "==> Installing $APP_DST (may prompt for your password)..."
sudo rm -rf "$APP_DST"
sudo cp -R "$APP_SRC" "$APP_DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DST" 2>/dev/null || true

# 4. Symlink the CLI for convenience.
echo "==> Linking CLI to $CLI_LINK..."
sudo install -d -m 755 "$PREFIX/bin"
sudo ln -sf "$EXEC" "$CLI_LINK"

# 5. Write the LaunchAgent plist.
echo "==> Installing LaunchAgent to $PLIST..."
mkdir -p "$HOME/Library/LaunchAgents"

ARGS_XML="        <string>$EXEC</string>"
for a in "$@"; do
    ARGS_XML="$ARGS_XML
        <string>$a</string>"
done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
$ARGS_XML
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/touchutil.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/touchutil.err.log</string>
</dict>
</plist>
EOF

# 6. (Re)load the agent.
echo "==> Starting the agent..."
if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    launchctl load "$PLIST" 2>/dev/null || true
fi

cat <<EOF

✅ Installed.

ONE-TIME PERMISSIONS — grant these to "touchutil" in System Settings:

  1. Input Monitoring → Privacy & Security → Input Monitoring → enable touchutil
  2. Accessibility    → Privacy & Security → Accessibility    → enable touchutil

  The agent retries automatically once permissions are granted.

Logs:      tail -f /tmp/touchutil.err.log
Verify:    pgrep -la touchutil
Setup:     touchutil --setup
Test:      touchutil --test
Uninstall: $REPO_ROOT/scripts/uninstall.sh
EOF
