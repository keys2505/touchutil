#!/bin/bash
#
# Install touchdriver as a per-user LaunchAgent so it starts automatically
# at login. Pass any touchdriver options as arguments to this script, e.g.:
#
#   ./scripts/install-launch-agent.sh --display-index 1
#
set -euo pipefail

LABEL="com.touchdriver.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="/usr/local/bin/touchdriver"

if [ ! -x "$BIN" ]; then
    echo "Error: $BIN not found. Build and install the binary first:"
    echo "  ./scripts/build-universal.sh"
    echo "  sudo cp <built-binary> /usr/local/bin/touchdriver"
    exit 1
fi

# Build the <array> of program arguments from this script's arguments.
ARGS_XML="        <string>$BIN</string>"
for a in "$@"; do
    ARGS_XML="$ARGS_XML
        <string>$a</string>"
done

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

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed and loaded LaunchAgent: $PLIST"
echo "Logs: /tmp/touchdriver.out.log  /tmp/touchdriver.err.log"
echo
echo "NOTE: grant Input Monitoring + Accessibility to /usr/local/bin/touchdriver"
echo "      under System Settings > Privacy & Security (the binary will appear"
echo "      in the lists the first time it runs)."
