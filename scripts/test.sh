#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 -m unittest discover -s "$ROOT/scripts/tests"
case "${1:-all}" in
  relaybar) packages=(Apps/RelayBar) ;;
  frame) packages=(Apps/Frame) ;;
  shared) packages=(Packages/AppComposition) ;;
  all) packages=(Packages/AppComposition Apps/RelayBar Apps/Frame) ;;
  *) echo "Usage: $0 [all|relaybar|frame|shared]" >&2; exit 2 ;;
esac
for package in "${packages[@]}"; do
  swift test --package-path "$ROOT/$package" -Xswiftc -warnings-as-errors
done
