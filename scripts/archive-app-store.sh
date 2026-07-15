#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer Team ID}"

cd "$ROOT"
xcodebuild \
  -project RelayBar.xcodeproj \
  -scheme RelayBar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ROOT/.build/RelayBar.xcarchive" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  -allowProvisioningUpdates \
  clean archive

echo "$ROOT/.build/RelayBar.xcarchive"
