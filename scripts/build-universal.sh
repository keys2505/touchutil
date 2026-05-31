#!/bin/bash
#
# Build a universal (arm64 + x86_64) release binary that runs on both
# Apple Silicon and Intel Macs.
#
# Uses swiftc + lipo so it works with only the Xcode Command Line Tools
# (full Xcode is NOT required).
#
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Sources/touchdriver/main.swift"
OUT_DIR="build"
DEPLOY="11.0"
mkdir -p "$OUT_DIR"

echo "Compiling arm64 slice..."
swiftc -O -target "arm64-apple-macosx${DEPLOY}"  "$SRC" -o "$OUT_DIR/touchdriver-arm64"

echo "Compiling x86_64 slice..."
swiftc -O -target "x86_64-apple-macosx${DEPLOY}" "$SRC" -o "$OUT_DIR/touchdriver-x86_64"

echo "Creating universal binary with lipo..."
lipo -create -output "$OUT_DIR/touchdriver" \
    "$OUT_DIR/touchdriver-arm64" "$OUT_DIR/touchdriver-x86_64"

rm -f "$OUT_DIR/touchdriver-arm64" "$OUT_DIR/touchdriver-x86_64"

# Code-sign (ad-hoc) with a stable, unique identifier so macOS has a
# consistent identity for privacy permissions. Note: rebuilding still changes
# the binary's code hash, so you may need to re-grant Input Monitoring /
# Accessibility after a rebuild.
BUNDLE_ID="${BUNDLE_ID:-com.eriproject.touchdriver}"
echo "Code-signing (ad-hoc, identifier=$BUNDLE_ID)..."
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT_DIR/touchdriver"

# Assemble a background .app bundle. Bundling gives macOS a stable, registered
# identity (the bundle id) so privacy permissions can be revoked with tccutil
# and are attributed cleanly when launched by launchd.
APP="$OUT_DIR/touchdriver.app"
echo "Assembling app bundle ($APP)..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT_DIR/touchdriver" "$APP/Contents/MacOS/touchdriver"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>touchdriver</string>
    <key>CFBundleExecutable</key>
    <string>touchdriver</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
echo "Code-signing app bundle (ad-hoc, identifier=$BUNDLE_ID)..."
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"

echo
echo "Built:"
echo "  CLI binary:  $OUT_DIR/touchdriver"
echo "  App bundle:  $APP"
file "$OUT_DIR/touchdriver"
echo
echo "Install with: ./scripts/install.sh"
