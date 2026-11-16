# Frame

Frame is a native macOS folder viewer for images, video, Markdown, HTML and text. Open an existing folder, browse its tree or contact sheet, and inspect files beside their metadata. Nothing is imported. General files stay visible even when they have no preview.

**Current source is under test; Frame has no public release yet.** Local folders work independently. Remote folders require a compatible RelayBar from the same source revision; the current bridge is v7, and older versions are rejected. See the [paired-app README](../../README.md) and [local installation evidence](../../docs/verification/063-one-markdown-renderer.md#local-installation).

## Review a folder

- Open… combines local and remote locations. Remote folders expand on demand; Subfolders scans progressively.
- Images and same-name companion files form one item. Favorites, Archive/Restore and exact-copy export work on the group.
- F or the heart favorites the current image and advances. Select mode keeps checked action targets while you preview other files.
- Local deletion uses macOS Trash with Undo. Remote Delete is immediate and permanent, without confirmation or Undo; Archive/Restore is a separate action.
- Resize contact-sheet thumbnails and the preview/metadata panes; sizes are remembered.
- Prompt Search is on by default: filter by filenames and companion text, with Command-F to focus it. Switch it in **Frame → Plugins…**, which also shows the running feature tree.

## Read documents

Markdown shares RelayBar's renderer: highlighted code with Copy, typeset math, frontmatter properties, callouts, footnotes and aligned tables in Frame's palette. Markdown HTML is shown literally, Mermaid stays source, and documents above 2 MiB skip enrichment. Frame can load Markdown images and follow neighbouring document links.

HTML previews run page scripts and may load online resources. The viewer exposes no file-action, shell or clipboard bridge to HTML. Documents are limited to 10 MiB. [Document and bridge boundaries](../../docs/system-specs/shared/security-boundaries.md).

Frame is sandboxed. Local access comes from user-selected folders. Remote access goes through RelayBar's authenticated local bridge; RelayBar owns SSH configuration and credentials. Preview caches are temporary and cleared when the session ends. Frame does not add to or change RelayBar's recent-folder history.

## Build and test

Requires macOS 14+, a Swift 6.2+ toolchain and the macOS SDK. From this directory:

```sh
swift build --product Frame
swift test -Xswiftc -warnings-as-errors
make app
open .build/app/Frame.app
```

`make app` creates a universal Release bundle for Apple Silicon and Intel, includes the highlighter and math-font resources, and signs with the sandbox entitlements in `AppBundle/Frame.entitlements`. A Developer ID Application certificate is required; override `SIGNING_IDENTITY` when needed. `./Scripts/build-app.sh debug` builds for the host architecture.

From the repository root, `./scripts/package-release.sh frame` creates `.build/Frame.zip`. After explicit distribution approval, `./scripts/notarize-release.sh frame` handles submission, stapling and final archive verification. See the [release guide](../../docs/system-specs/operations/build-and-release.md) for the required environment and paired rollout order. Frame has no automatic updater or Homebrew cask.

The [system specs](../../docs/system-specs/modules/frame-viewer.md) describe current behavior. Earlier Frame design and verification records remain under [docs](docs/README.md).
