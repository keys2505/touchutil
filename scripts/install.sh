#!/bin/bash
#
# install.sh — build, install, and start touchutil on macOS.
#
# What it does:
#   1. Builds the universal binary + app bundle if not already built.
#   2. Installs touchutil.app to /Applications — needs sudo.
#   3. Symlinks the CLI to $PREFIX/bin/touchutil for `--setup`, `--list-*`.
#   4. Installs a per-user LaunchAgent so it runs at login and restarts itself.
#   5. Loads the agent and prints the one-time permission steps.
#
# Any extra arguments are passed through to touchutil in the LaunchAgent,
# e.g.:  ./scripts/install.sh --display-index 1
# (Normally none are needed — touchutil auto-detects the touchscreen.)
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

# 1. Build if needed.
if [ ! -d "$APP_SRC" ]; then
    echo "==> Building..."
    "$REPO_ROOT/scripts/build-universal.sh"
fi

# 2. Install the app bundle (sudo) and register it with LaunchServices.
echo "==> Installing $APP_DST (may prompt for your password)..."
sudo rm -rf "$APP_DST"
sudo cp -R "$APP_SRC" "$APP_DST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DST" 2>/dev/null || true

# 3. Symlink the CLI for convenience (touchutil --setup, --list-displays...).
echo "==> Linking CLI to $CLI_LINK..."
sudo install -d -m 755 "$PREFIX/bin"
sudo ln -sf "$EXEC" "$CLI_LINK"

# 4. Write the LaunchAgent plist.
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

# 5. (Re)load the agent — modern bootstrap with a fallback to load.
echo "==> Loading the agent..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
fi

cat <<EOF

✅ Installed.

ONE-TIME PERMISSIONS — grant these to "touchutil":

  1. Input Monitoring:
       open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
  2. Accessibility:
       open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

  Enable "touchutil" in BOTH lists (remove any stale entry with the – button
  first). The agent retries every ~10s and starts automatically once granted.

Logs:    /tmp/touchutil.err.log
Verify:  pgrep -la touchutil && tail -3 /tmp/touchutil.err.log
Pick a specific display:  touchutil --setup
Uninstall:                $REPO_ROOT/scripts/uninstall.sh
EOF
