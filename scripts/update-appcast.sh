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

PRODUCTION_PLIST="$ROOT/Apps/RelayBar/Packaging/Info.plist"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PRODUCTION_PLIST")"
EXPECTED_FEED="$(plutil -extract SUFeedURL raw "$PRODUCTION_PLIST")"
EXPECTED_KEY="$(plutil -extract SUPublicEDKey raw "$PRODUCTION_PLIST")"
# The App Group RelayBar is signed with carries the Developer ID team as its prefix.
APP_GROUP="$(plutil -extract 'com\.apple\.security\.application-groups.0' raw "$ROOT/Apps/RelayBar/Packaging/RelayBar.entitlements")"
TEAM="${APP_GROUP%%.*}"
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Cannot read the Developer ID team from RelayBar's App Group: $APP_GROUP" >&2
  exit 1
fi

RELAYBAR_TEMP="$(mktemp -d /tmp/relaybar-update-appcast.XXXXXX)"
NEW_APPCAST=""
cleanup() {
  if [[ -d "$RELAYBAR_TEMP" && "$RELAYBAR_TEMP" == /tmp/relaybar-update-appcast.* ]]; then
    rm -rf -- "$RELAYBAR_TEMP"
  fi
  if [[ -n "$NEW_APPCAST" && -f "$NEW_APPCAST" ]]; then
    rm -f -- "$NEW_APPCAST"
  fi
}
trap cleanup EXIT

mkdir "$RELAYBAR_TEMP/archives" "$RELAYBAR_TEMP/extracted"
STAGED_ARCHIVE="$RELAYBAR_TEMP/archives/RelayBar.zip"
EXTRACTED_APP="$RELAYBAR_TEMP/extracted/RelayBar.app"
cp "$ARCHIVE" "$STAGED_ARCHIVE"

# Sign only the final archive: verify the bytes to be signed from a clean extraction.
# The requirement is the one the bridge applies to RelayBar: its identifier and team.
ditto -x -k "$STAGED_ARCHIVE" "$RELAYBAR_TEMP/extracted"
codesign --verify --deep --strict \
  -R="=anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM\"" \
  "$EXTRACTED_APP"
xcrun stapler validate "$EXTRACTED_APP"
spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"
python3 "$ROOT/scripts/release-plan.py" relaybar --archive "$STAGED_ARCHIVE"

# The build must update from the production feed with the key this account signs with.
if [[ "$(plutil -extract SUFeedURL raw "$EXTRACTED_APP/Contents/Info.plist")" != "$EXPECTED_FEED" ]]; then
  echo "The archive's SUFeedURL differs from the production Info.plist." >&2
  exit 1
fi
if [[ "$(plutil -extract SUPublicEDKey raw "$EXTRACTED_APP/Contents/Info.plist")" != "$EXPECTED_KEY" ]]; then
  echo "The archive's SUPublicEDKey differs from the production Info.plist." >&2
  exit 1
fi
if [[ "$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" != "$EXPECTED_KEY" ]]; then
  echo "The Keychain signing key does not match SUPublicEDKey." >&2
  exit 1
fi

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

# Replace the repository feed only after the staged one verifies, and never leave it half written.
"$ROOT/scripts/verify-update-feed.sh" "$RELAYBAR_TEMP/archives/appcast.xml"
NEW_APPCAST="$(mktemp "$APPCAST.XXXXXX")"
chmod 644 "$NEW_APPCAST"
cp "$RELAYBAR_TEMP/archives/appcast.xml" "$NEW_APPCAST"
mv -f "$NEW_APPCAST" "$APPCAST"
echo "$APPCAST"
