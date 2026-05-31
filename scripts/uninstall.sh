#!/bin/bash
#
# uninstall.sh — stop and remove touchdriver from macOS.
#
# Removes the LaunchAgent and the installed binary. Pass --purge to also delete
# the saved configuration (~/.config/touchdriver).
#
# Note: macOS privacy permissions (Input Monitoring / Accessibility) must be
# removed by hand in System Settings if you want them gone — there is no
# supported CLI to revoke them.
#
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
BIN_DST="$PREFIX/bin/touchdriver"
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

# 2. Kill any lingering process — match by exact process name so it catches
#    both the installed binary and any copy started by hand.
echo "==> Stopping any running touchdriver process..."
pkill -x touchdriver 2>/dev/null || true
sleep 1
pkill -9 -x touchdriver 2>/dev/null || true

# 3. Best-effort revoke of privacy permissions (only works if the tool is a
#    signed .app bundle; plain CLI binaries are not addressable by tccutil, so
#    this is expected to no-op — the manual note below still applies).
if [ -e "$BIN_DST" ]; then
    ID="$(codesign -dv "$BIN_DST" 2>&1 | awk -F= '/^Identifier=/{print $2}')"
    if [ -n "${ID:-}" ]; then
        tccutil reset Accessibility "$ID" >/dev/null 2>&1 || true
        tccutil reset ListenEvent  "$ID" >/dev/null 2>&1 || true
    fi
fi

# 4. Remove the binary (sudo).
if [ -e "$BIN_DST" ]; then
    echo "==> Removing $BIN_DST (may prompt for your password)..."
    sudo rm -f "$BIN_DST"
fi

# 4. Optionally remove saved config.
if [ "$PURGE" -eq 1 ]; then
    echo "==> Removing saved config $CONFIG_DIR..."
    rm -rf "$CONFIG_DIR"
fi

# 5. Clean up logs.
rm -f /tmp/touchdriver.out.log /tmp/touchdriver.err.log

cat <<EOF

✅ Uninstalled.

If you want to fully remove the privacy permissions, delete the "touchdriver"
entries by hand in System Settings > Privacy & Security >
Input Monitoring and Accessibility.
EOF
