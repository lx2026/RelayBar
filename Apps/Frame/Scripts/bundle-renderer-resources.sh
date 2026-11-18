#!/bin/zsh

# Copies the Markdown renderer's resource bundles and their licences into an app's
# Contents/Resources, keeping only the theme and math font the renderer uses.
# The generated bundle accessor looks only beside the app, so a missing bundle stops the app at first use.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <binary-directory> <checkouts-directory> <resources-directory>" >&2
  exit 2
fi
binary_directory="$1"
checkouts_directory="$2"
resources_directory="$3"
if [[ ! -d "$resources_directory" ]]; then
  echo "Resources directory does not exist: $resources_directory" >&2
  exit 1
fi

for bundle in Highlighter_Highlighter SwiftMath_SwiftMath; do
  if [[ ! -d "$binary_directory/$bundle.bundle" ]]; then
    echo "Required resource bundle was not built: $bundle.bundle" >&2
    exit 1
  fi
  rm -rf "$resources_directory/$bundle.bundle"
  cp -R "$binary_directory/$bundle.bundle" "$resources_directory/"
  # Pruning breaks the seal the build gave the bundle; the app's own signature covers its files.
  rm -rf "$resources_directory/$bundle.bundle/Contents/_CodeSignature"
done

highlighter_root="$resources_directory/Highlighter_Highlighter.bundle"
theme_directory="$highlighter_root/Contents/Resources"
if [[ ! -d "$theme_directory" ]]; then
  theme_directory="$highlighter_root"
fi
for resource in highlight.min.js github.css github-dark.css; do
  if [[ ! -f "$theme_directory/$resource" ]]; then
    echo "Required Highlighter resource was not found: $resource" >&2
    exit 1
  fi
done
find "$theme_directory" -maxdepth 1 -type f -name '*.css' \
  ! -name 'github.css' \
  ! -name 'github-dark.css' \
  -delete

math_root="$resources_directory/SwiftMath_SwiftMath.bundle"
font_directory="$math_root/Contents/Resources/mathFonts.bundle"
if [[ ! -d "$font_directory" ]]; then
  font_directory="$math_root/mathFonts.bundle"
fi
if [[ ! -f "$font_directory/latinmodern-math.otf" || ! -f "$font_directory/latinmodern-math.plist" ]]; then
  echo "SwiftMath's default Latin Modern resources were not found." >&2
  exit 1
fi
find "$font_directory" -type f \
  \( -name '*.otf' -o -name '*.plist' \) \
  ! -name 'latinmodern-math.otf' \
  ! -name 'latinmodern-math.plist' \
  -delete
find "$font_directory" -type f -name 'math_table_to_plist.py' -delete

cp "$checkouts_directory/HighlighterSwift/LICENCE.md" "$resources_directory/Highlighter-LICENSE.txt"
cp "$checkouts_directory/HighlighterSwift/Sources/Assets/LICENCE" "$resources_directory/highlight.js-LICENSE.txt"
cp "$checkouts_directory/SwiftMath/LICENSE" "$resources_directory/SwiftMath-LICENSE.txt"
cp "$checkouts_directory/SwiftMath/Sources/SwiftMath/mathFonts.bundle/GUST-FONT-LICENSE.txt" "$resources_directory/LatinModern-LICENSE.txt"
