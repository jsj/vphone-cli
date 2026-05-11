#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${SCRIPT_DIR}/VPhoneIdentitySpoof.dylib"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

xcrun --sdk iphoneos clang \
  -arch arm64 -arch arm64e \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -dynamiclib \
  -Wl,-undefined,dynamic_lookup \
  -fobjc-arc \
  -framework Foundation \
  -framework CoreFoundation \
  "$SCRIPT_DIR/VPhoneIdentitySpoof.m" \
  -o "$OUT"

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT"
fi

echo "$OUT"
