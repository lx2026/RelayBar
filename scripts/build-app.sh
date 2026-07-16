#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

case "$CONFIGURATION" in
  debug|Debug)
    XCODE_CONFIGURATION="Debug"
    DESTINATION="platform=macOS"
    ;;
  release|Release)
    XCODE_CONFIGURATION="Release"
    DESTINATION="generic/platform=macOS"
    ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

cd "$ROOT"
DERIVED_DATA="$ROOT/.build/LocalDerivedData"
APP="$ROOT/.build/RelayBar.app"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning |
      sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' |
      head -n 1
  )"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No Developer ID Application certificate was found." >&2
  echo "Set SIGNING_IDENTITY to the certificate name shown by: security find-identity -v -p codesigning" >&2
  exit 1
fi

xcodebuild \
  -project RelayBar.xcodeproj \
  -scheme RelayBar \
  -configuration "$XCODE_CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

rm -rf "$APP"
cp -R "$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/RelayBar.app" "$APP"
codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --timestamp \
  "$APP" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Signed with: $SIGNING_IDENTITY"
echo "$APP"
