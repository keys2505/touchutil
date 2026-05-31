#!/bin/bash
#
# Build a universal (arm64 + x86_64) release binary that runs on both
# Apple Silicon and Intel Macs.
#
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building universal release binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/touchdriver

echo
echo "Built: $BIN"
file "$BIN"
echo
echo "Install it to /usr/local/bin with:"
echo "  sudo cp \"$BIN\" /usr/local/bin/touchdriver"
