#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="${1:-}"
ARCHIVE="${2:-}"
PORT="${3:-}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.lx2026.RelayBar}"
EXPECTED_KEY="$(plutil -extract SUPublicEDKey raw "$ROOT/Apps/RelayBar/Packaging/Info.plist")"

if [[ -z "$APPCAST" || -z "$ARCHIVE" || -z "$PORT" ]]; then
  echo "Usage: $0 <private-appcast.xml> <RelayBar.zip> <loopback-port>" >&2
  exit 2
fi
if [[ ! -f "$APPCAST" || ! -f "$ARCHIVE" ]]; then
  echo "The private appcast and archive must both exist." >&2
  exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
  echo "The loopback port must be an integer from 1024 through 65535." >&2
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
if [[ -z "$EXPECTED_KEY" || "$KEYCHAIN_PUBLIC_KEY" != "$EXPECTED_KEY" ]]; then
  echo "The Keychain signing key does not match SUPublicEDKey." >&2
  exit 1
fi
"$SPARKLE_BIN/sign_update" \
  --account "$SPARKLE_ACCOUNT" \
  --verify "$APPCAST"

RELAYBAR_PRIVATE_TEMP="$(mktemp -d /tmp/relaybar-private-feed.XXXXXX)"
cleanup() {
  if [[ -d "$RELAYBAR_PRIVATE_TEMP" && "$RELAYBAR_PRIVATE_TEMP" == /tmp/relaybar-private-feed.* ]]; then
    rm -rf -- "$RELAYBAR_PRIVATE_TEMP"
  fi
}
trap cleanup EXIT

python3 - "$APPCAST" <<'PY' > "$RELAYBAR_PRIVATE_TEMP/enclosure.tsv"
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit("The private appcast must contain exactly one item.")
enclosure = items[0].find("enclosure")
if enclosure is None:
    raise SystemExit("The private appcast must contain exactly one enclosure.")
attributes = {
    key.rsplit("}", 1)[-1]: value
    for key, value in enclosure.attrib.items()
}
version = items[0].find(
    "{http://www.andymatuschak.org/xml-namespaces/sparkle}version"
)
row = (
    attributes.get("url", ""),
    attributes.get("length", ""),
    attributes.get("edSignature", ""),
    version.text.strip() if version is not None and version.text else "",
)
if not all(row):
    raise SystemExit("The private enclosure is incomplete.")
print("\t".join(row))
PY

IFS=$'\t' read -r URL LENGTH SIGNATURE BUILD < "$RELAYBAR_PRIVATE_TEMP/enclosure.tsv"
if [[ "$URL" != "http://127.0.0.1:$PORT/RelayBar.zip" ]]; then
  echo "Unexpected private enclosure URL: $URL" >&2
  exit 1
fi
if [[ ! "$LENGTH" =~ ^[0-9]+$ ]] || [[ "$LENGTH" != "$(stat -f '%z' "$ARCHIVE")" ]]; then
  echo "The private enclosure length does not match the archive." >&2
  exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]] || (( BUILD <= 0 )); then
  echo "The private enclosure build must be a positive integer." >&2
  exit 1
fi
"$SPARKLE_BIN/sign_update" \
  --account "$SPARKLE_ACCOUNT" \
  --verify "$ARCHIVE" "$SIGNATURE"

echo "Verified private signed update build $BUILD on loopback port $PORT."
