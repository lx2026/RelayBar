#!/bin/zsh

set -euo pipefail

build_configuration="${1:-release}"
build_arguments=(-c "$build_configuration")
case "$build_configuration" in
  release) build_arguments+=(--arch arm64 --arch x86_64) ;;
  debug) ;;
  *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

swift build "${build_arguments[@]}" --product Frame
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
if [[ "$build_configuration" == release ]]; then
  for architecture in arm64 x86_64; do
    lipo "$binary_directory/Frame" -verify_arch "$architecture"
  done
fi
app_directory="$repository_root/.build/app/Frame.app"

rm -rf "$app_directory"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$repository_root/AppBundle/Info.plist" "$app_directory/Contents/Info.plist"
cp "$binary_directory/Frame" "$app_directory/Contents/MacOS/Frame"
cp "$repository_root/AppBundle/Resources/AppIcon.icns" "$app_directory/Contents/Resources/AppIcon.icns"
cp "$repository_root/.build/checkouts/swift-cmark/COPYING" "$app_directory/Contents/Resources/Markdown-LICENSE.txt"
"$repository_root/Scripts/bundle-renderer-resources.sh" "$binary_directory" "$repository_root/.build/checkouts" "$app_directory/Contents/Resources"

signing_identity="${SIGNING_IDENTITY:-Developer ID Application: Thought Tides LLC (39HYFR5Z65)}"
codesign --force --sign "$signing_identity" --options runtime --timestamp \
  --entitlements "$repository_root/AppBundle/Frame.entitlements" "$app_directory"
codesign --verify --strict --verbose=2 "$app_directory"
echo "$app_directory"
