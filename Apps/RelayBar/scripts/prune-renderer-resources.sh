#!/usr/bin/env bash
set -euo pipefail

bundle_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/SwiftMath_SwiftMath.bundle"
font_directory="${bundle_root}/Contents/Resources/mathFonts.bundle"
if [[ ! -d "$font_directory" ]]; then
  font_directory="${bundle_root}/mathFonts.bundle"
fi

case "$font_directory" in
  "$bundle_root"/*/mathFonts.bundle|"$bundle_root"/mathFonts.bundle) ;;
  *) echo "Refusing to prune an unexpected path: $font_directory" >&2; exit 1 ;;
esac

if [[ ! -f "$font_directory/latinmodern-math.otf" ||
      ! -f "$font_directory/latinmodern-math.plist" ]]; then
  echo "SwiftMath's default Latin Modern resources were not found." >&2
  exit 1
fi

find "$font_directory" -type f \
  \( -name '*.otf' -o -name '*.plist' \) \
  ! -name 'latinmodern-math.otf' \
  ! -name 'latinmodern-math.plist' \
  -delete
find "$font_directory" -type f -name 'math_table_to_plist.py' -delete

highlighter_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Highlighter_Highlighter.bundle"
theme_directory="${highlighter_root}/Contents/Resources"
if [[ ! -d "$theme_directory" ]]; then
  theme_directory="$highlighter_root"
fi

case "$theme_directory" in
  "$highlighter_root"/Contents/Resources|"$highlighter_root") ;;
  *) echo "Refusing to prune an unexpected path: $theme_directory" >&2; exit 1 ;;
esac

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
