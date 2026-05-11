#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${SCRIPT_DIR}/TweakLoader.dylib"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"

"$CC" -isysroot "$SDK" \
  -arch arm64 -arch arm64e \
  -miphoneos-version-min=15.0 \
  -dynamiclib \
  -fobjc-arc -O3 \
  -framework Foundation \
  -o "$OUT" \
  "$SCRIPT_DIR/TweakLoader.m"

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT"
fi

echo "$OUT"
