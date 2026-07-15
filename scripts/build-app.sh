#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"

case "$CONFIGURATION" in
  debug|Debug) XCODE_CONFIGURATION="Debug" ;;
  release|Release) XCODE_CONFIGURATION="Release" ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

cd "$ROOT"
DERIVED_DATA="$ROOT/.build/LocalDerivedData"
APP="$ROOT/.build/RelayBar.app"

xcodebuild \
  -project RelayBar.xcodeproj \
  -scheme RelayBar \
  -configuration "$XCODE_CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

rm -rf "$APP"
cp -R "$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/RelayBar.app" "$APP"
codesign --force --sign - --options runtime --entitlements "$ROOT/Packaging/RelayBar.entitlements" "$APP" >/dev/null

echo "$APP"
