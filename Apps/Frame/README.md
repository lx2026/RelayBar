# Frame

Frame is a native macOS folder viewer for images, video, Markdown, HTML and text. Open an existing folder, browse its tree or thumbnails, and inspect files beside their metadata. Nothing is imported. General files stay visible even when they have no preview.

- **Stable 1.6.0:** there is no stable Frame release, and stable RelayBar 1.6.0 does not include the Frame integration.
- Frame 2.0.0 Beta 3 (build 23) runs on macOS 14 or later and is the final release for Intel Macs. Subsequent releases require Apple silicon. [Download Beta 3](https://github.com/lx2026/RelayBar/releases/tag/frame-v2.0.0-beta.3)

Local folders work independently. For remote folders in Beta 3, use RelayBar 2.0.0 Beta 3. Development builds can pair with RelayBar from the same source revision. [RelayBar Beta 3](https://github.com/lx2026/RelayBar/releases/tag/v2.0.0-beta.3)

Both apps use bridge v7, and older bridge versions are rejected. Frame updates manually. Hand acceptance in the running app and against live SSH hosts is not finished. See the [paired-app README](../../README.md) and the [reader layout verification](../../docs/verification/068-frame-reader-layout.md).

## Review a folder

- The window has two columns. The library column holds the Files/Icons switch, the search field, the folder tree and a footer with the kind filter, favourites only and Archive. The root row's menu has Open…, Parent Folder and Refresh.
- Open… combines local and remote locations. Remote folders expand on demand; Subfolders scans progressively.
- Files mode shows one file with its name, kind, Previous/Next, Favorite, Archive, Move to Trash (Delete in a remote folder) and More. Images and video sit beside a details rail: generation prompt and negative text, capture or video values, sidecar files and file details.
- Icons mode shows the folder as thumbnails, with kind chips, Subfolders, Select and a size slider.
- Images and same-name companion files form one item. A sidecar such as `image.png.json` shows as a `{ }` chip and in the details rail; **Show Sidecar Files** lists sidecars again. Favorites, Archive/Restore and exact-copy export work on the group.
- F or the heart favorites the current image and advances. Select mode keeps checked action targets while you preview other files.
- A dot marks files changed since they were last opened in Frame. Only file times are compared, never the Mac's clock, and the first listing of a folder sets its baseline, so nothing is marked then.
- Local deletion uses macOS Trash with Undo. Remote Delete is immediate and permanent, without confirmation or Undo; Archive/Restore is a separate action.
- Drag the divider to size the library column between 200 and 420 points. The column width and thumbnail size are remembered.
- Prompt Search is on by default: filter by filenames and companion text, with Command-F to focus it. Paper Appearance, also on by default, draws Frame's warm paper colours; off, Frame uses standard macOS colours. Switch either in **Frame → Plugins…**, which also shows a map of the running features.

## Read documents

Markdown shares RelayBar's renderer: highlighted code with Copy, typeset math, frontmatter properties, callouts, footnotes and aligned tables in Frame's palette. Markdown HTML is shown literally, Mermaid stays source, and documents above 2 MiB skip enrichment. Frame can load Markdown images and follow neighbouring document links.

Markdown and HTML have a Rendered/Source switch; Source shows the file's own text, monospaced and wrapped. Beside rendered Markdown, **On this page** lists the second- and third-level headings, marks the section being read and scrolls to a heading you choose. It is hidden with fewer than two headings, when the column is too narrow, and after Hide Details.

HTML previews run page scripts and may load online resources. An HTML page fills the reader column as a white card. The viewer exposes no file-action, shell or clipboard bridge to HTML. Documents are limited to 10 MiB. [Document and bridge boundaries](../../docs/system-specs/shared/security-boundaries.md).

Frame is sandboxed. Local access comes from user-selected folders. Remote access goes through RelayBar's authenticated local bridge; RelayBar owns SSH configuration and credentials, and asks once before Frame may reach remote folders. Remote folders need Python 3 on the server; image previews and metadata also need Pillow, and video posters ffmpeg and ffprobe. Nothing is installed on the server automatically. Preview caches are temporary and cleared when the session ends. Frame does not add to or change RelayBar's recent-folder history.

## Build and test

Build and test on an Apple silicon Mac with macOS 14+, a Swift 6.2+ toolchain and the macOS SDK. From this directory:

```sh
swift build --product Frame
swift test -Xswiftc -warnings-as-errors
make app
open .build/app/Frame.app
```

`make app` creates an arm64 Release bundle, includes the highlighter and math-font resources, and signs with the sandbox entitlements in `AppBundle/Frame.entitlements`. A Developer ID Application certificate is required; override `SIGNING_IDENTITY` when needed. `./Scripts/build-app.sh debug` packages an arm64 Debug build.

From the repository root, `./scripts/package-release.sh frame` creates `.build/Frame.zip`. After explicit distribution approval, `./scripts/notarize-release.sh frame` handles submission, stapling and final archive verification. See the [release guide](../../docs/system-specs/operations/build-and-release.md) for the required environment and paired rollout order. Frame has no automatic updater or Homebrew cask.

The [system specs](../../docs/system-specs/modules/frame-viewer.md) describe current behavior. Earlier Frame design and verification records remain under [docs](docs/README.md).
