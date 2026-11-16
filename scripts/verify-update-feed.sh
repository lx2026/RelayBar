#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="${1:-$ROOT/docs/appcast.xml}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.lx2026.RelayBar}"
EXPECTED_FEED="$(plutil -extract SUFeedURL raw "$ROOT/Apps/RelayBar/Packaging/Info.plist")"
EXPECTED_KEY="$(plutil -extract SUPublicEDKey raw "$ROOT/Apps/RelayBar/Packaging/Info.plist")"
REQUIRES_SIGNED_FEED="$(
  plutil -extract SURequireSignedFeed raw "$ROOT/Apps/RelayBar/Packaging/Info.plist"
)"
VERIFIES_BEFORE_EXTRACTION="$(
  plutil -extract SUVerifyUpdateBeforeExtraction raw "$ROOT/Apps/RelayBar/Packaging/Info.plist"
)"

if [[ "$EXPECTED_FEED" != "https://lx2026.github.io/RelayBar/appcast.xml" ]]; then
  echo "Unexpected production feed URL: $EXPECTED_FEED" >&2
  exit 1
fi
if [[ -z "$EXPECTED_KEY" || "$EXPECTED_KEY" == *PLACEHOLDER* ]]; then
  echo "A production Sparkle public key is required." >&2
  exit 1
fi
if [[ "$REQUIRES_SIGNED_FEED" != "true" || "$VERIFIES_BEFORE_EXTRACTION" != "true" ]]; then
  echo "Signed-feed and pre-extraction verification must both be enabled." >&2
  exit 1
fi

xmllint --noout "$APPCAST"

SPARKLE_BIN="${SPARKLE_BIN:-$(find "$ROOT/.build" "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin' -type d -print -quit 2>/dev/null)}"
if [[ ! -x "$SPARKLE_BIN/sign_update" || ! -x "$SPARKLE_BIN/generate_keys" ]]; then
  echo "Sparkle release tools were not found. Resolve the Xcode packages first." >&2
  exit 1
fi

KEYCHAIN_PUBLIC_KEY="$(
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p
)"
if [[ "$KEYCHAIN_PUBLIC_KEY" != "$EXPECTED_KEY" ]]; then
  echo "The Keychain signing key does not match SUPublicEDKey." >&2
  exit 1
fi
"$SPARKLE_BIN/sign_update" \
  --account "$SPARKLE_ACCOUNT" \
  --verify "$APPCAST"

RELAYBAR_TEMP="$(mktemp -d /tmp/relaybar-verify-appcast.XXXXXX)"
cleanup() {
  if [[ -d "$RELAYBAR_TEMP" && "$RELAYBAR_TEMP" == /tmp/relaybar-verify-appcast.* ]]; then
    rm -rf -- "$RELAYBAR_TEMP"
  fi
}
trap cleanup EXIT

python3 - "$APPCAST" <<'PY' > "$RELAYBAR_TEMP/enclosures.tsv"
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
rows = []
for item in root.findall("./channel/item"):
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    attributes = {key.rsplit("}", 1)[-1]: value for key, value in enclosure.attrib.items()}
    version = item.find(
        "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
    )
    rows.append((
        attributes.get("url", ""),
        attributes.get("length", ""),
        attributes.get("edSignature", ""),
        version.text.strip() if version is not None and version.text else "",
    ))
if not rows:
    raise SystemExit("The appcast contains no full-update enclosures.")
previous_build = None
for url, length, signature, build in rows:
    row = (url, length, signature, build)
    if not all(row):
        raise SystemExit("An appcast enclosure is missing URL, length, signature, or build.")
    if not length.isdecimal() or int(length) <= 0:
        raise SystemExit(f"Invalid enclosure length for build {build!r}.")
    if not build.isdecimal() or int(build) <= 0:
        raise SystemExit(f"Invalid numeric build number: {build!r}.")
    numeric_build = int(build)
    if previous_build is not None and numeric_build >= previous_build:
        raise SystemExit(
            f"Appcast builds are not strictly descending: "
            f"{previous_build} then {numeric_build}."
        )
    previous_build = numeric_build
    print("\t".join(row))
PY

while IFS=$'\t' read -r URL LENGTH SIGNATURE BUILD; do
  if [[ "$URL" != https://* ]]; then
    echo "Non-HTTPS update URL: $URL" >&2
    exit 1
  fi
  ARCHIVE_PATH="$RELAYBAR_TEMP/RelayBar-$BUILD.zip"
  curl --fail --location --silent --show-error "$URL" --output "$ARCHIVE_PATH"
  ACTUAL_LENGTH="$(stat -f '%z' "$ARCHIVE_PATH")"
  if [[ "$ACTUAL_LENGTH" != "$LENGTH" ]]; then
    echo "Length mismatch for build $BUILD." >&2
    exit 1
  fi
  "$SPARKLE_BIN/sign_update" \
    --account "$SPARKLE_ACCOUNT" \
    --verify "$ARCHIVE_PATH" "$SIGNATURE"
done < "$RELAYBAR_TEMP/enclosures.tsv"

echo "Verified $(wc -l < "$RELAYBAR_TEMP/enclosures.tsv" | tr -d ' ') signed update enclosure(s)."
