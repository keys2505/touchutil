#!/bin/bash
#
# uninstall.sh — stop and fully remove touchutil from macOS.
#
# Options:
#   --purge   also delete saved config (~/.config/touchutil)
#
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BUNDLE_ID="${BUNDLE_ID:-com.eriproject.touchutil}"
APP_DST="/Applications/touchutil.app"
CLI_LINK="$PREFIX/bin/touchutil"
LABEL="com.touchutil.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
CONFIG_DIR="$HOME/.config/touchutil"

PURGE=0
for a in "$@"; do
    case "$a" in
        --purge) PURGE=1 ;;
        *) echo "Unknown option: $a"; echo "Usage: uninstall.sh [--purge]"; exit 2 ;;
    esac
done

# 1. Stop and remove the LaunchAgent.
echo "==> Stopping the agent..."
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

# 2. Kill any lingering process.
echo "==> Stopping any running touchutil process..."
pkill -x touchutil 2>/dev/null || true

# 3. Revoke privacy permissions.
echo "==> Revoking privacy permissions..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ListenEvent   "$BUNDLE_ID" 2>/dev/null || true

# 4. Remove the app bundle and CLI symlink (sudo).
echo "==> Removing app and CLI link (may prompt for your password)..."
sudo rm -rf "$APP_DST"  2>/dev/null || true
sudo rm -f  "$CLI_LINK" 2>/dev/null || true

# 5. Optionally remove saved config.
if [ "$PURGE" -eq 1 ]; then
    echo "==> Removing saved config $CONFIG_DIR..."
    rm -rf "$CONFIG_DIR"
fi

# 6. Clean up logs.
rm -f /tmp/touchutil.out.log /tmp/touchutil.err.log /tmp/touchutil.debug.log

echo ""
echo "✅ Uninstalled. App, login agent, CLI link, and permissions removed."
echo "   If a stale 'touchutil' row still shows in System Settings → Privacy & Security,"
echo "   it will clear automatically after a logout or restart."
