# UX parity

Read across for current behaviour. The last column records the direction of change. A dash means the app has no corresponding surface.

### Browsing and opening files

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Folder order | Folders first, then name | Folder tree first, name within groups | Folders first, newest within groups by default | [Listing], [Scanner], [Sidebar], [Folder] | To fix | Folders list newest first by default. |
| Hidden entries | Lists dot names inline | Local scanner skips them, bridge lists them | Collapsed hidden count with Show | [Listing], [Scanner], [Helper], [Remote client], [Folder] | To fix | Names that begin with a dot are tucked into one row with Show. |
| Keeping an item | — | Pin / Unpin | Pin / Unpin | [Sidebar], [Screen], [Website browser] | Same | Use the pin glyph. |
| Markdown extensions | md, markdown, mdown, mkd | md, markdown, mdown, mkd | md, markdown, mdown, mkd | [Preview policy], [Grouping] | Same | Group and render all four extensions. |
| Image formats | JPEG and PNG plus More Image Formats | JPEG and PNG plus More Image Formats | JPEG and PNG plus More Image Formats | [Preview policy] | Same | More Image Formats starts enabled. |
| Video formats | MP4, MOV, M4V | MP4, MOV, M4V | MP4, MOV, M4V | [Preview policy] | Same | Use the same list for opening and labelling video. |
| Companion files | Bridge groups by owner name | Scanner attaches ranked sidecars | Folder row holds the same ordered companions | [Helper], [Grouping], [Frame pairs], [Reader] | Same | Keep folder boundaries, ambiguous stems and independent documents in the shared cases. |
| Size of remote listings | 10,000 entries | 10,000 entries | 10,000 entries | [Preview policy], [Listing], [Helper], [Transport] | Same | Enforce the shared entry limit. |

### Reading and image details

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Markdown layout | Shared renderer | Shared renderer | Shared renderer | [Relay Markdown], [Frame page], [Reader] | Same | Keep the common document cases. |
| Images in Markdown | Placeholder for a relative image | Resolves relative assets | Resolves relative assets through the host file service | [Relay Markdown], [Frame renderer], [Document scheme], [Reader] | Different on purpose | Preserve RelayBar’s self-contained preview and the readers’ file-backed images. |
| Rendered Markdown colours | Reader paper and green accents | Reader paper and green accents | Reader paper and green accents | [Document paper] | Same | Use the shared light and dark rules. |
| Plain-text page | — | Escaped text on reader paper | Escaped text on reader paper | [Document paper], [Frame page], [Reader] | Same | Follow the selected appearance for text and source. |
| Markdown size | 10 MiB | 10 MiB | 10 MiB | [Preview policy] | Same | Apply the document limit. |
| HTML size | 10 MiB | 10 MiB | 10 MiB | [Preview policy] | Same | Apply the document limit. |
| HTML page assets | 32 MiB per asset, 64 MiB total, 128 distinct requests | Same budgets | Same budgets | [Preview policy], [Relay HTML], [Frame resources], [Document scheme] | Same | Bound resources per page. |
| PNG text | Bridge helper reads Pillow text fields | Swift chunk reader | Separate Swift chunk reader | [Helper], [Frame PNG], [Mobile PNG] | To fix | Share decoding rules and bounded-text fixtures. |
| Embedded PNG text limits | Pillow caps decompressed chunks at 1 MiB, total at 2 MiB | Decompresses a chunk with a 64 MiB ceiling | 256,000-byte buffer and combined text budget | [Helper], [Frame PNG], [Mobile PNG] | To fix | Agree on the limits for readable embedded text. |
| Image details | Helper supplies text and EXIF to Frame | Interprets generator parameters and camera fields | Reads raw keys and presents selected fields | [Helper], [Frame metadata], [Reader], [Screen] | To fix | Give equivalent metadata the same labels. |
| Graph in the Prompt field | Helper forwards raw metadata | Suppresses object-shaped prompt text | Suppresses node graphs for display and prompt search | [Helper], [Frame metadata], [Reader], [Observers], [Screen] | Same | Keep workflow graphs out of the prompt. |
| Companion text budget | 32 files, 2 MiB each, 256,000 characters total | Same limits | Same limits | [Preview policy], [Helper], [Frame metadata], [Reader] | Same | Clip decoded text to the remaining budget. |

### Websites and connections

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Web service noun | Website Labels | — | Website Labels | [Preview policy], [Tunnel list], [Website browser] | Same | Use Website for the page and tunnel for the forwarding rule. |
| Website name | Known product, then page title | — | Known product, then page title | [Website name policy] | Same | Use the same recognition order and title limit. |
| Host-key failure | Could not verify the server’s key | Remote access through RelayBar | Distinguishes changed and refused keys | [SFTP], [Transport], [Remote client] | To fix | Use consistent trust wording for equivalent failures. |
| Connection failure | Server refused, timed out or connection lost | Remote access through RelayBar | Service refused or SSH connection ended | [SFTP], [Transport], [Remote client] | To fix | Match equivalent causes and keep actionable recovery details. |
| Shared plugin text | Website Labels and appearance | Prompt Search and appearance | Website Labels, Prompt Search and appearance | [Preview policy], [Paper appearance] | Same | Use one title and summary per shared plugin, including More Image Formats. |

### Counting rules

**Definitions.** Count one per backticked source excerpt in the inventory below that still exists in the linked file. Count a format registry, switch or named extension set as one table, a light/dark palette as one palette, and a PNG extraction implementation as one reader (including Pillow). Count each separately set byte or count budget listed below, including equal values in different definitions. The inventory tracks cross-app preview, directory and label policies. A lookup, an individual format check inside a renderer, and a transport implementation detail add no entry. When a definition moves or is shared, update the inventory. A missing excerpt prints a diagnostic.

| Kind | Source | Definitions |
|---|---|---|
| PNG | [Helper] | `im.info.items()` |
| PNG | [Frame PNG] | `case "tEXt":` |
| PNG | [Mobile PNG] | `case "tEXt":` |
| Limit | [Frame PNG] | `let maximum = 64 *` |
| Limit | [Mobile PNG] | `var remaining = 256_000`, `var length: uLongf = 256_000` |
| Limit | [Helper] | `MAX_TEXT_CHUNK=1024*1024`, `MAX_TEXT_MEMORY=2*1024*1024` |
| Limit | [Relay JSON] | `maximumByteCount = 2 *` |
| Limit | [Relay video] | `maximumByteCount: Int64 = 512 *` |
| Limit | [Structured reader] | `static let limit = 2 << 20` |

**Fixture coverage.** The denominator is one case per named entry in [Grouping fixtures] and one per HTML reference page alongside [ordinary] and [extended]. Count a grouping case in the numerator when both the [Mac grouping test] and [mobile grouping test] enumerate the whole fixture array. Count a Markdown case when both the [Mac Markdown test] and [mobile Markdown test] select its name in their fixture loops. This measures test wiring. The mobile Markdown test checks the complete stylesheet and paper palette before comparing the fixture markup.

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
[Preview policy]: ../../../Packages/AppComposition/Sources/PreviewSupport/PreviewPolicy.swift
[Website name policy]: ../../../Packages/AppComposition/Sources/PreviewSupport/WebsiteName.swift
[Document paper]: ../../../Packages/AppComposition/Sources/HouseStyle/DocumentPaper.swift
[Structured reader]: ../../../Apps/RelayBarMobile/Sources/MobileCore/StructuredPreview.swift
[Paper appearance]: ../../../Packages/AppComposition/Sources/HouseStyle/PaperAppearance.swift
