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

# Code-sign (ad-hoc) so the binary has a stable identity for macOS privacy
# permissions. Note: rebuilding changes the binary, so you may need to
# re-grant Input Monitoring / Accessibility after a rebuild.
echo "Code-signing (ad-hoc)..."
codesign --force --sign - "$OUT_DIR/touchdriver"

echo
echo "Built: $OUT_DIR/touchdriver"
file "$OUT_DIR/touchdriver"
echo
echo "Install it to /usr/local/bin with:"
echo "  sudo cp \"$OUT_DIR/touchdriver\" /usr/local/bin/touchdriver"
