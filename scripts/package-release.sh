#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then echo "Usage: $0 [relaybar|frame]" >&2; exit 2; fi
case "${1:-relaybar}" in
  relaybar)
    APP="$ROOT/.build/RelayBar.app"
    ZIP="$ROOT/.build/RelayBar.zip"
    "$ROOT/scripts/build-app.sh" release
    ;;
  frame)
    APP="$ROOT/Apps/Frame/.build/app/Frame.app"
    ZIP="$ROOT/.build/Frame.zip"
    "$ROOT/Apps/Frame/Scripts/build-app.sh" release
    ;;
  *) echo "Usage: $0 [relaybar|frame]" >&2; exit 2 ;;
esac

mkdir -p "$ROOT/.build"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "$ZIP"
