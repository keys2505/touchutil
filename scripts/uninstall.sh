#!/bin/bash
#
# uninstall.sh — stop and remove touchdriver from macOS.
#
# Removes the LaunchAgent, the app bundle, and the CLI symlink, and revokes the
# Input Monitoring / Accessibility permissions via tccutil. Pass --purge to also
# delete the saved configuration (~/.config/touchdriver).
#
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BUNDLE_ID="${BUNDLE_ID:-com.eriproject.touchdriver}"
APP_DST="/Applications/touchdriver.app"
CLI_LINK="$PREFIX/bin/touchdriver"
LABEL="com.touchdriver.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
CONFIG_DIR="$HOME/.config/touchdriver"

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

# 2. Kill any lingering process (by exact name, catches hand-started copies too).
echo "==> Stopping any running touchdriver process..."
pkill -x touchdriver 2>/dev/null || true
sleep 1
pkill -9 -x touchdriver 2>/dev/null || true

# 3. Revoke privacy permissions by bundle id.
echo "==> Revoking privacy permissions ($BUNDLE_ID)..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ListenEvent  "$BUNDLE_ID" 2>/dev/null || true

# 4. Remove the app bundle and CLI symlink (sudo).
if [ -e "$APP_DST" ] || [ -L "$CLI_LINK" ]; then
    echo "==> Removing $APP_DST and $CLI_LINK (may prompt for your password)..."
    sudo rm -rf "$APP_DST"
    sudo rm -f "$CLI_LINK"
fi

# 5. Optionally remove saved config.
if [ "$PURGE" -eq 1 ]; then
    echo "==> Removing saved config $CONFIG_DIR..."
    rm -rf "$CONFIG_DIR"
fi

# 6. Clean up logs.
rm -f /tmp/touchdriver.out.log /tmp/touchdriver.err.log

cat <<EOF

✅ Uninstalled. The app, login agent, CLI link, and privacy permissions have
   been removed. If a stale "touchdriver" row still shows in System Settings >
   Privacy & Security, it is harmless and clears after a logout/restart.
EOF
