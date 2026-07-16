#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/RelayBar.app"
ZIP="$ROOT/.build/RelayBar.zip"

"$ROOT/scripts/build-app.sh" release

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "$ZIP"
