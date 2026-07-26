# Build and Release

## Requirements

- macOS 13 or newer
- Xcode command-line tools
- Developer ID Application certificate for packaged builds

## Commands

- `swift test` runs the package tests.
- `./scripts/build-app.sh` builds and signs `.build/RelayBar.app`.
- `./scripts/package-release.sh` creates `.build/RelayBar.zip`.
- `./scripts/notarize-release.sh` submits, waits, staples, and validates a release.

The Xcode target prunes unused renderer resources from the generated app bundle. It retains Highlighter's formatter and the two themes RelayBar selects, plus SwiftMath's default Latin Modern font, metrics, and bundled font licenses. It removes the other highlight themes, alternate math fonts, and SwiftMath's package-development conversion script. Source dependencies remain unchanged and every clean build reproduces the same pruning step.

Release builds generate a dSYM and then apply non-global symbol stripping to the installed executable. Debug builds remain unstripped. The dSYM and executable UUIDs must match before a release artifact is accepted.

The app is distributed outside the Mac App Store, uses the hardened runtime, and is intentionally not sandboxed.

## Project Website

The GitHub Pages site is a build-free static site under `docs/`. Its
`index.html`, `styles.css`, and local image assets are sufficient to render the
page; it does not require a generated page runtime or third-party font request.
Release download links identify the current stable version explicitly.
