# UX parity

Read across for current behaviour. The last column records the direction of change. A dash means the app has no corresponding surface.

### Browsing and opening files

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Folder order | Folders first, then name | Folder tree first, name within groups | Folders first, newest within groups by default | [Listing], [Scanner], [Sidebar], [Folder] | To fix | Folders list newest first by default. |
| Hidden entries | Lists dot names inline | Local scanner skips them, bridge lists them | Collapsed hidden count with Show | [Listing], [Scanner], [Helper], [Remote client], [Folder] | To fix | Names that begin with a dot are tucked into one row with Show. |
| Keeping an item | — | Favorite, with a heart | Pin / Unpin | [Sidebar], [Screen], [Website browser] | To fix | The verb for keeping a folder, file or website is Pin. |
| Markdown extensions | md, markdown, mdown, mkd | md, markdown | Same four as RelayBar | [Relay formats], [Frame formats], [Frame page], [Reader] | To fix | Recognise the four extensions consistently, including when grouping files. |
| Image formats | JPEG, PNG, BMP, GIF, HEIC/HEIF, TIFF | JPEG, PNG | JPEG, PNG, GIF, HEIC, WebP, TIFF | [Relay formats], [Photo format], [Reader], [Folder] | To fix | JPEG and PNG open in every app, and other image formats come from one plugin that is on by default. |
| Video formats | MP4 | MP4, MOV, M4V | Same three as Frame, plus a video glyph for WebM | [Relay formats], [Frame formats], [Reader], [Folder] | To fix | Use one list for opening and labelling playable formats. |
| Companion files | Bridge groups by owner name | Scanner attaches ranked sidecars | Folder row holds the same ordered companions | [Helper], [Grouping], [Frame pairs], [Reader] | Same | Keep folder boundaries, ambiguous stems and independent documents in the shared cases. |
| Size of remote listings | 10,000 entries | Bridge helper caps a directory at 10,000 | 10,000 entries | [Listing], [Helper], [Bridge], [Remote client], [Transport] | Same | Define the remote entry limit once. |

### Reading and image details

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Markdown layout | Shared renderer | Shared renderer | Shared renderer | [Relay Markdown], [Frame page], [Reader] | Same | Keep the common document cases. |
| Images in Markdown | Placeholder for a relative image | Resolves relative assets | Resolves relative assets through the host file service | [Relay Markdown], [Frame renderer], [Document scheme], [Reader] | Different on purpose | Preserve RelayBar’s self-contained preview and the readers’ file-backed images. |
| Rendered Markdown colours | Default white/dark stylesheet | Reader paper, green accents | Copies Frame’s palette. Golden skips CSS | [Relay Markdown], [Frame page], [Reader] | To fix | Rendered Markdown uses the paper palette in every app. |
| Plain-text page | — | Escaped text on reader paper | Escaped text on reader paper | [Frame page], [Reader], [Screen] | Same | Follow the selected appearance for text and source. |
| Markdown size | 2 MiB | 10 MiB | 2 MiB | [Relay Markdown], [Frame formats], [Frame resources], [Reader] | To fix | Choose one Markdown limit. |
| HTML size | 10 MiB | 10 MiB | 2 MiB | [Relay HTML], [Frame resources], [Frame formats], [Reader] | To fix | Define the HTML limit once. |
| HTML page assets | 32 MiB per asset, 64 MiB total, 128 requests for distinct paths | Same budgets | Up to 100 MiB per asset | [Relay HTML], [Frame resources], [Document scheme], [Reader] | To fix | Agree on per-file and per-page budgets. |
| PNG text | Bridge helper reads Pillow text fields | Swift chunk reader | Separate Swift chunk reader | [Helper], [Frame PNG], [Mobile PNG] | To fix | Share decoding rules and bounded-text fixtures. |
| Embedded PNG text limits | Pillow caps decompressed chunks at 1 MiB, total at 2 MiB | Decompresses a chunk with a 64 MiB ceiling | 256,000-byte buffer and combined text budget | [Helper], [Frame PNG], [Mobile PNG] | To fix | Agree on the limits for readable embedded text. |
| Image details | Helper supplies text and EXIF to Frame | Interprets generator parameters and camera fields | Reads raw keys and presents selected fields | [Helper], [Frame metadata], [Reader], [Screen] | To fix | Give equivalent metadata the same labels. |
| Graph in the Prompt field | Helper forwards raw metadata | Suppresses object-shaped prompt text | Suppresses node graphs for display and prompt search | [Helper], [Frame metadata], [Reader], [Observers], [Screen] | Same | Keep workflow graphs out of the prompt. |
| Companion text budget | Helper reads up to 2 MiB each, clips combined text | 2 MiB each, 256,000 characters combined | Up to 32 files, 256,000 bytes combined | [Helper], [Frame sidecars], [Frame metadata], [Remote client], [Reader] | To fix | Use the same units and truncation rules. |

### Websites and connections

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Web service noun | Tunnel with Open in Browser, Service Labels plugin | — | Website | [Tunnel list], [Relay plugins], [Website browser] | To fix | The noun for a web service a person opens is Website. |
| Website name | Recognises known products, then tries the title | — | Page title | [Relay labels], [Mobile labels] | To fix | Share product recognition and title fallback. |
| Host-key failure | Could not verify the server’s key | Remote access through RelayBar | Distinguishes changed and refused keys | [SFTP], [Transport], [Remote client] | To fix | Use consistent trust wording for equivalent failures. |
| Connection failure | Server refused, timed out or connection lost | Remote access through RelayBar | Service refused or SSH connection ended | [SFTP], [Transport], [Remote client] | To fix | Match equivalent causes and keep actionable recovery details. |

### Counting rules

**Definitions.** Count one per backticked source excerpt in the inventory below that still exists in the linked file. Count a format registry, switch or named extension set as one table, a light/dark palette as one palette, and a PNG extraction implementation as one reader (including Pillow). Count each separately set byte or count budget listed below, including equal values in different definitions. The inventory tracks cross-app preview, directory and label policies. A lookup, an individual format check inside a renderer, and a transport implementation detail add no entry. When a definition moves or is shared, update the inventory. A missing excerpt prints a diagnostic.

| Kind | Source | Definitions |
|---|---|---|
| Table | [Relay formats] | `extensions: ["bmp"` |
| Table | [Helper] | `MEDIA = {`, `DOCUMENTS = {` |
| Table | [Photo format] | `switch pathExtension.lowercased()`, `static let textExtensions:` |
| Table | [Frame formats] | `extensions: ["jpg"` |
| Table | [Reader] | `case .markdown: extensions =` |
| Table | [Folder] | `["png", "jpg"`, `case "mp4", "mov"` |
| Palette | [Frame page] | `--md-text:#242821` |
| Palette | [Reader] | `--md-text:#242821` |
| PNG | [Helper] | `im.info.items()` |
| PNG | [Frame PNG] | `case "tEXt":` |
| PNG | [Mobile PNG] | `case "tEXt":` |
| Limit | [Frame PNG] | `let maximum = 64 *` |
| Limit | [Mobile PNG] | `var remaining = 256_000`, `var length: uLongf = 256_000` |
| Limit | [Listing] | `maximumEntryCount = 10_000` |
| Limit | [Helper] | `if len(names) > 10000`, `remaining=256000`, `if sideinfo.st_size>2*1024*1024`, `MAX_TEXT_CHUNK=1024*1024`, `MAX_TEXT_MEMORY=2*1024*1024` |
| Limit | [Bridge] | `entries.count <= 10_000`, `previewSizeLimit: 100 *`, `videoPreviewSizeLimit: 100 *`, `originalLimit: Int64 = 100 *` |
| Limit | [Transport] | `rows.count < 10_000` |
| Limit | [Relay Markdown] | `maximumByteCount = 2 *` |
| Limit | [Relay JSON] | `maximumByteCount = 2 *` |
| Limit | [Relay video] | `maximumByteCount: Int64 = 512 *` |
| Limit | [Relay formats] | `maximumBytes: 100 *` |
| Limit | [SFTP] | `previewSizeLimit: Int64 = 100 *` |
| Limit | [Relay HTML] | `documentLimit = 10 *`, `resourceLimit = 32 *`, `requested.count < 128`, `bytes.count <= 64 *` |
| Limit | [Frame resources] | `documentLimit = 10 *`, `resourceLimit = 32 *`, `sessionLimit = 64 *`, `loaded.count < 128` |
| Limit | [Frame formats] | `["md", "markdown"], maximumBytes: 10`, `["html", "htm"], maximumBytes: 10`, `textExtensions, maximumBytes: 10`, `["*"], maximumBytes: 10` |
| Limit | [Frame sidecars] | `maximumBytes = 2 *` |
| Limit | [Frame metadata] | `var remaining = 256_000` |
| Limit | [Remote client] | `remaining = 256_000`, `entries.count <= 10_000`, `let limit: Int64 = 100 *` |
| Limit | [Reader] | `.image ? 100 << 20`, `: 2 << 20)`, `var remaining = 256_000`, `companions.prefix(32)`, `min(remaining, 2 << 20)` |
| Limit | [Document scheme] | `limit: 100 << 20` |
| Limit | [Relay labels] | `titleLimit = 40`, `byteLimit = 64 *` |
| Limit | [Mobile labels] | `title.prefix(40)`, `buffer.count == 65536` |

**Fixture coverage.** The denominator is one case per named entry in [Grouping fixtures] and one per HTML reference page alongside [ordinary] and [extended]. Count a grouping case in the numerator when both the [Mac grouping test] and [mobile grouping test] enumerate the whole fixture array. Count a Markdown case when both the [Mac Markdown test] and [mobile Markdown test] select its name in their fixture loops. This measures test wiring. The mobile Markdown golden compares markup after the style block, so these cases cannot detect palette drift.

**Outstanding rows.** Count each behaviour whose Status cell reads “To fix”. The total line repeats the three measures together. Only a missing linked file makes the check fail.

[Bridge]: ../../../Apps/RelayBar/Sources/RelayBar/FrameBridgeBroker.swift
[Listing]: ../../../Apps/RelayBar/Sources/RelayBar/RemoteFile.swift
[Helper]: ../../../Apps/RelayBar/Sources/RelayBar/FrameRemoteHelper.swift
[Relay formats]: ../../../Apps/RelayBar/Sources/RelayBar/RemotePreviewPlugins.swift
[Relay Markdown]: ../../../Apps/RelayBar/Sources/RelayBar/MarkdownPreview.swift
[Relay HTML]: ../../../Apps/RelayBar/Sources/RelayBar/HTMLPreview.swift
[Relay JSON]: ../../../Apps/RelayBar/Sources/RelayBar/RemoteFilesModel.swift
[Relay video]: ../../../Apps/RelayBar/Sources/RelayBar/RemoteVideoPreview.swift
[SFTP]: ../../../Apps/RelayBar/Sources/RelayBar/SFTPRemoteFileService.swift
[Relay labels]: ../../../Apps/RelayBar/Sources/RelayBar/ServiceLabels.swift
[Tunnel list]: ../../../Apps/RelayBar/Sources/RelayBar/RelayBarRootView.swift
[Relay plugins]: ../../../Apps/RelayBar/Sources/RelayBar/RelayPlugins.swift
[Scanner]: ../../../Apps/Frame/Sources/FrameKit/Services/FileScanner.swift
[Sidebar]: ../../../Apps/Frame/Sources/Frame/Views/FolderSidebar.swift
[Photo format]: ../../../Apps/Frame/Sources/FrameKit/Models/PhotoItem.swift
[Frame formats]: ../../../Apps/Frame/Sources/FrameKit/Services/FrameComposition.swift
[Frame page]: ../../../Apps/Frame/Sources/FrameKit/Services/DocumentHTML.swift
[Frame renderer]: ../../../Apps/Frame/Sources/FrameKit/Services/DocumentRenderer.swift
[Frame resources]: ../../../Apps/Frame/Sources/FrameKit/Services/DocumentResources.swift
[Frame pairs]: ../../../Apps/Frame/Sources/FrameKit/Services/AssetPairing.swift
[Frame PNG]: ../../../Apps/Frame/Sources/FrameKit/Services/PNGTextReader.swift
[Frame metadata]: ../../../Apps/Frame/Sources/FrameKit/Services/ImageMetadataReader.swift
[Frame sidecars]: ../../../Apps/Frame/Sources/FrameKit/Services/SidecarReader.swift
[Remote client]: ../../../Apps/Frame/Sources/FrameKit/Services/RelayRemoteClient.swift
[Folder]: ../../../Apps/RelayBarMobile/Sources/MobileUI/FolderScreen.swift
[Screen]: ../../../Apps/RelayBarMobile/Sources/MobileUI/ReaderScreen.swift
[Reader]: ../../../Apps/RelayBarMobile/Sources/MobileCore/Reader.swift
[Document scheme]: ../../../Apps/RelayBarMobile/Sources/MobileCore/DocumentScheme.swift
[Mobile PNG]: ../../../Apps/RelayBarMobile/Sources/MobileCore/PNGTextReader.swift
[Observers]: ../../../Apps/RelayBarMobile/Sources/MobileCore/Registries.swift
[Transport]: ../../../Apps/RelayBarMobile/Sources/MobileCore/TransportAdapter.swift
[Mobile labels]: ../../../Apps/RelayBarMobile/Sources/MobileCore/ServiceLabels.swift
[Website browser]: ../../../Apps/RelayBarMobile/Sources/MobileUI/ServiceBrowser.swift
[Grouping]: ../../../Packages/AppComposition/Sources/AssetGrouping/AssetCompanionNames.swift
[Grouping fixtures]: ../../../Packages/AppComposition/Sources/CompositionFixtures/CompanionGroupingFixtures.swift
[Mac grouping test]: ../../../Apps/Frame/Tests/FrameKitTests/AssetTests.swift
[Mobile grouping test]: ../../../Apps/RelayBarMobile/Tests/MobileCoreTests/RemainingReadersTests.swift
[Mac Markdown test]: ../../../Packages/AppComposition/Tests/MarkdownRenderingTests/ReferenceOutputTests.swift
[Mobile Markdown test]: ../../../Apps/RelayBarMobile/Tests/MobileCoreTests/MobileTests.swift
[ordinary]: ../../../Packages/AppComposition/Tests/MarkdownRenderingTests/ReferencePages/ordinary.html
[extended]: ../../../Packages/AppComposition/Tests/MarkdownRenderingTests/ReferencePages/extended.html
