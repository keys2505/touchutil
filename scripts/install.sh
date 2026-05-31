#!/bin/bash
#
# install.sh — build, install, and start touchdriver on macOS.
#
# What it does:
#   1. Builds the universal binary if it isn't already built.
#   2. Installs it to $PREFIX/bin (default /usr/local/bin) — needs sudo.
#   3. Installs a per-user LaunchAgent so it runs at login and restarts itself.
#   4. Loads the agent and prints the one-time permission steps.
#
# Any extra arguments are passed through to touchdriver in the LaunchAgent,
# e.g. to pin a display:  ./scripts/install.sh --display-index 1
# (Normally none are needed — touchdriver auto-detects the touchscreen.)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN_SRC="$REPO_ROOT/build/touchdriver"
BIN_DST="$PREFIX/bin/touchdriver"
LABEL="com.touchdriver.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# 1. Build if needed.
if [ ! -x "$BIN_SRC" ]; then
    echo "==> Building universal binary..."
    "$REPO_ROOT/scripts/build-universal.sh"
fi

# 2. Install the binary (sudo).
echo "==> Installing binary to $BIN_DST (may prompt for your password)..."
sudo install -d -m 755 "$PREFIX/bin"
sudo install -m 755 "$BIN_SRC" "$BIN_DST"

# 3. Write the LaunchAgent plist.
echo "==> Installing LaunchAgent to $PLIST..."
mkdir -p "$HOME/Library/LaunchAgents"

ARGS_XML="        <string>$BIN_DST</string>"
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
    <string>/tmp/touchdriver.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/touchdriver.err.log</string>
</dict>
</plist>
EOF

# 4. (Re)load the agent — modern bootstrap with a fallback to load.
echo "==> Loading the agent..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
fi

cat <<EOF

✅ Installed.

ONE-TIME PERMISSIONS — grant these to "$BIN_DST":

  1. Input Monitoring:
       open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
  2. Accessibility:
       open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

  Enable "touchdriver" in BOTH lists (remove any stale entry with the – button
  first). The agent retries every ~10s and will start automatically once both
  are granted.

Logs:    /tmp/touchdriver.err.log
Verify:  pgrep -la touchdriver && tail -3 /tmp/touchdriver.err.log
Setup a specific display:  $BIN_DST --setup
Uninstall:                 $REPO_ROOT/scripts/uninstall.sh
EOF
