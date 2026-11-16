#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then echo "Usage: $0 [relaybar|frame]" >&2; exit 2; fi
SELECTED_APP="${1:-relaybar}"
case "$SELECTED_APP" in
  relaybar) NAME="RelayBar"; APP="$ROOT/.build/RelayBar.app" ;;
  frame) NAME="Frame"; APP="$ROOT/Apps/Frame/.build/app/Frame.app" ;;
  *) echo "Usage: $0 [relaybar|frame]" >&2; exit 2 ;;
esac
ZIP="$ROOT/.build/$NAME.zip"
RESULT="$ROOT/.build/notarization-$SELECTED_APP.json"

source "$ROOT/scripts/require-publication-approval.sh"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

"$ROOT/scripts/package-release.sh" "$SELECTED_APP"
codesign --verify --deep --strict "$APP"

xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format json > "$RESULT"

STATUS="$(plutil -extract status raw -o - "$RESULT")"
if [[ "$STATUS" != Accepted ]]; then
  echo "$NAME notarization was not accepted ($STATUS). See $RESULT and retrieve the submission log with notarytool." >&2
  exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=4 "$APP"

# Verify the actual distribution archive after stapling, from a clean extraction.
EXTRACTED="$(mktemp -d "${TMPDIR:-/tmp}/$NAME-notarized.XXXXXX")"
trap 'rm -rf "$EXTRACTED"' EXIT
ditto -x -k "$ZIP" "$EXTRACTED"
codesign --verify --deep --strict "$EXTRACTED/$NAME.app"
xcrun stapler validate "$EXTRACTED/$NAME.app"
spctl --assess --type execute --verbose=4 "$EXTRACTED/$NAME.app"
python3 "$ROOT/scripts/release-plan.py" "$SELECTED_APP" --archive "$ZIP"

echo "$ZIP"
