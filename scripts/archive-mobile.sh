#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
project=Apps/RelayBarMobile/RelayBarMobile.xcodeproj
plist=Apps/RelayBarMobile/App/Info.plist
archive=.build/RelayBarMobile.xcarchive
key=ITSAppUsesNonExemptEncryption

case "$#:${1:-}" in
  0:) ;;
  1:--dry-run)
    echo "Would check DEVELOPMENT_TEAM and $key in $plist."
    echo "Would archive RelayBarMobile (Release, generic/platform=iOS) to $archive."
    exit 0 ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Set DEVELOPMENT_TEAM to your signing team." >&2
  exit 1
fi
if ! plutil -extract "$key" raw -expect bool "$plist" >/dev/null 2>&1; then
  echo "Set $key in $plist to the maintainer's confirmed boolean declaration." >&2
  exit 1
fi

mkdir -p .build
if ! xcodebuild -project "$project" -scheme RelayBarMobile -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" archive; then
  echo "Archive failed. Check the build diagnostics and locally installed signing certificate and provisioning profile." >&2
  exit 1
fi
echo "Archive: $archive"
