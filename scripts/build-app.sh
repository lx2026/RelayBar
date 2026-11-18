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
  -project Apps/RelayBar/RelayBar.xcodeproj \
  -scheme RelayBar \
  -configuration "$XCODE_CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

rm -rf "$APP"
cp -R "$DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/RelayBar.app" "$APP"

SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FRAMEWORK/Versions/B"
if [[ ! -d "$SPARKLE_VERSION" ]]; then
  echo "Sparkle.framework is missing from the built app." >&2
  exit 1
fi

# Sparkle contains nested executable code. Sign every boundary inside-out so
# the final app seal and each helper retain a valid hardened-runtime identity.
for component in \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION/Autoupdate" \
  "$SPARKLE_VERSION/Updater.app"
do
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --preserve-metadata=entitlements,requirements,flags \
    "$component" >/dev/null
done

codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --timestamp \
  "$SPARKLE_FRAMEWORK" >/dev/null
codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ROOT/Apps/RelayBar/Packaging/RelayBar.entitlements" \
  "$APP" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP"

for component in \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION/Updater.app" \
  "$SPARKLE_FRAMEWORK"
do
  codesign --verify --strict --verbose=2 "$component"
done

echo "Signed with: $SIGNING_IDENTITY"
echo "$APP"
