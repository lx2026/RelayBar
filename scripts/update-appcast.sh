#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/require-publication-approval.sh"
ARCHIVE="${1:-}"
DOWNLOAD_URL="${2:-}"
APPCAST="$ROOT/docs/appcast.xml"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.lx2026.RelayBar}"

if [[ -z "$ARCHIVE" || -z "$DOWNLOAD_URL" ]]; then
  echo "Usage: $0 <final-stapled-RelayBar.zip> <immutable-download-url>" >&2
  exit 2
fi
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Archive not found: $ARCHIVE" >&2
  exit 1
fi
if [[ "$DOWNLOAD_URL" != https://* ]]; then
  echo "The download URL must use HTTPS." >&2
  exit 1
fi

SPARKLE_BIN="${SPARKLE_BIN:-$(find "$ROOT/.build" "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d -print -quit 2>/dev/null)}"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Sparkle release tools were not found. Resolve the Xcode packages first." >&2
  exit 1
fi

RELAYBAR_TEMP="$(mktemp -d /tmp/relaybar-update-appcast.XXXXXX)"
cleanup() {
  if [[ -d "$RELAYBAR_TEMP" && "$RELAYBAR_TEMP" == /tmp/relaybar-update-appcast.* ]]; then
    rm -rf -- "$RELAYBAR_TEMP"
  fi
}
trap cleanup EXIT

mkdir "$RELAYBAR_TEMP/archives" "$RELAYBAR_TEMP/extracted"
STAGED_ARCHIVE="$RELAYBAR_TEMP/archives/RelayBar.zip"
cp "$ARCHIVE" "$STAGED_ARCHIVE"

# Sign only the final archive: verify the bytes to be signed from a clean extraction.
ditto -x -k "$STAGED_ARCHIVE" "$RELAYBAR_TEMP/extracted"
codesign --verify --deep --strict "$RELAYBAR_TEMP/extracted/RelayBar.app"
xcrun stapler validate "$RELAYBAR_TEMP/extracted/RelayBar.app"
spctl --assess --type execute --verbose=4 "$RELAYBAR_TEMP/extracted/RelayBar.app"
python3 "$ROOT/scripts/release-plan.py" relaybar --archive "$STAGED_ARCHIVE"

curl --fail --location --silent --show-error \
  "$DOWNLOAD_URL" \
  --output "$RELAYBAR_TEMP/public-RelayBar.zip"
if ! cmp -s "$STAGED_ARCHIVE" "$RELAYBAR_TEMP/public-RelayBar.zip"; then
  echo "The public archive differs from the final stapled archive." >&2
  exit 1
fi

if [[ -f "$APPCAST" ]]; then
  cp "$APPCAST" "$RELAYBAR_TEMP/archives/appcast.xml"
fi
"$SPARKLE_BIN/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "${DOWNLOAD_URL%/*}/" \
  --link "https://lx2026.github.io/RelayBar/" \
  --maximum-versions 0 \
  "$RELAYBAR_TEMP/archives"

# Replace the repository feed only after the staged one verifies.
"$ROOT/scripts/verify-update-feed.sh" "$RELAYBAR_TEMP/archives/appcast.xml"
cp "$RELAYBAR_TEMP/archives/appcast.xml" "$APPCAST"
echo "$APPCAST"
