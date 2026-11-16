#!/usr/bin/env bash
set -euo pipefail

# Frame requires Swift 6.2. Runner defaults may lag an installed compatible Xcode.
supports_packages() {
  local version
  [[ -d "$1/Platforms/MacOSX.platform" ]] || return 1
  version="$(DEVELOPER_DIR="$1" /usr/bin/xcrun swift --version 2>/dev/null)" || return 1
  if [[ "$version" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
    (( BASH_REMATCH[1] > 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] >= 2) ))
  else
    return 1
  fi
}

selected="$(/usr/bin/xcode-select -p)"
if ! supports_packages "$selected"; then
  selected=""
  for candidate in /Applications/Xcode*.app/Contents/Developer; do
    if [[ -d "$candidate" ]] && supports_packages "$candidate"; then
      selected="$candidate"
      break
    fi
  done
fi

if [[ -z "$selected" ]]; then
  echo "No installed Xcode provides Swift 6.2 or newer for the monorepo." >&2
  exit 1
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'DEVELOPER_DIR=%s\n' "$selected" >> "$GITHUB_ENV"
fi
printf 'Selected Xcode: %s\n' "$selected"
DEVELOPER_DIR="$selected" /usr/bin/xcrun swift --version
