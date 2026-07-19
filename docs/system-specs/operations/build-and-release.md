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

The app is distributed outside the Mac App Store, uses the hardened runtime, and is intentionally not sandboxed.
