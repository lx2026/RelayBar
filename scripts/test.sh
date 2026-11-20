#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-all}" in
  relaybar) packages=(Apps/RelayBar) ;;
  frame) packages=(Apps/Frame) ;;
  parity) exec python3 "$ROOT/scripts/parity.py" ;;
  shared) packages=(Packages/AppComposition) ;;
  mobile) packages=(Apps/RelayBarMobile) ;;
  transport) packages=(Packages/RelayTransport) ;;
  all) packages=(Packages/RelayTransport Packages/AppComposition Apps/RelayBar Apps/Frame Apps/RelayBarMobile) ;;
  *) echo "Usage: $0 [all|relaybar|frame|shared|transport|mobile|parity]" >&2; exit 2 ;;
esac
python3 -m unittest discover -s "$ROOT/scripts/tests"
for package in "${packages[@]}"; do
  swift test --package-path "$ROOT/$package" -Xswiftc -warnings-as-errors
  if [[ "$package" == Apps/RelayBarMobile ]]; then
    python3 "$ROOT/$package/Tests/WebFixtures/private_tls.py" swift run --package-path "$ROOT/$package" WebViewCheck
  fi
done
