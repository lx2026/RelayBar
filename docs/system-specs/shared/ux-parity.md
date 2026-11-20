# UX parity

Read across for current behaviour. The last column records the direction of change. A dash means the app has no corresponding surface.

### Browsing and opening files

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Folder order | Newest first within folders and files | Same | Same by default, with a saved Name option | [Folder listing] | Same | Break ties by natural name order. |
| Hidden entries | Count and Show | Count and Show in local and remote folders | Count and Show | [Folder listing] | Same | Reveal dot names for the current folder visit. |
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
| PNG text | Bridge reads text with Pillow | Shared Swift reader | Shared Swift reader | [Helper], [PNG reader] | Same | Read Latin-1 and international text, including compressed chunks. |
| Embedded PNG text limits | 1 MiB per chunk, 2 MiB per image | Same | Same | [Preview policy], [PNG reader], [Helper] | Same | Bound decompressed text. |
| Image details | Helper supplies text and EXIF to Frame | Prompt, negative prompt, settings, camera | Same | [Image details], [Frame metadata], [Reader] | Same | Use the shared labels and field order. |
| Graph in the Prompt field | Helper forwards raw metadata | Suppresses object-shaped prompt text | Suppresses node graphs for display and prompt search | [Helper], [Frame metadata], [Reader], [Observers], [Screen] | Same | Keep workflow graphs out of the prompt. |
| Companion text budget | 32 files, 2 MiB each, 256,000 characters total | Same limits | Same limits | [Preview policy], [Helper], [Frame metadata], [Reader] | Same | Clip decoded text to the remaining budget. |

### Websites and connections

| Behaviour | RelayBar | Frame | Mobile | Where decided | Status | Direction |
|---|---|---|---|---|---|---|
| Web service noun | Website Labels | — | Website Labels | [Preview policy], [Tunnel list], [Website browser] | Same | Use Website for the page and tunnel for the forwarding rule. |
| Website name | Known product, then page title | — | Known product, then page title | [Website name policy] | Same | Use the same recognition order and title limit. |
| Host-key failure | Distinct changed and untrusted key messages | Receives the RelayBar message | Same | [Connection failures], [SFTP], [Transport] | Same | Verify the fingerprint before trusting the key. |
| Connection failure | Title and recovery for each recognized cause | Receives the RelayBar message | Same for recognized causes | [Connection failures], [SFTP], [Transport], [Website browser] | Same | Keep generic reachability wording when SSH reports no specific cause. |
| Shared plugin text | Website Labels and appearance | Prompt Search and appearance | Website Labels, Prompt Search and appearance | [Preview policy], [Paper appearance] | Same | Use one title and summary per shared plugin, including More Image Formats. |

### Counting rules

**Definitions.** Count one per backticked source excerpt in the inventory below that still exists in the linked file. Count a format registry, switch or named extension set as one table, a light/dark palette as one palette, and a PNG extraction implementation as one reader (including Pillow). Count each separately set byte or count budget listed below, including equal values in different definitions. The inventory tracks cross-app preview, directory and label policies. A lookup, an individual format check inside a renderer, and a transport implementation detail add no entry. When a definition moves or is shared, update the inventory. A missing excerpt prints a diagnostic.

| Kind | Source | Definitions |
|---|---|---|
| PNG | [Helper] | `im.text if im.format == 'PNG'` |
| Limit | [Relay JSON] | `maximumByteCount = 2 *` |
| Limit | [Relay video] | `maximumByteCount: Int64 = 512 *` |
| Limit | [Structured reader] | `static let limit = 2 << 20` |

**Fixture coverage.** The grouping and Markdown counts include one case per named entry in [Grouping fixtures] and one per HTML reference page alongside [ordinary] and [extended]. Count a grouping case in the numerator when both the [Mac grouping test] and [mobile grouping test] enumerate the whole fixture array. Count a Markdown case when both the [Mac Markdown test] and [mobile Markdown test] select its name in their fixture loops. This measures test wiring. The mobile Markdown test checks the complete stylesheet and paper palette before comparing the fixture markup.

The browsing cases in [Browsing fixtures] cover both sort orders, hidden names, image metadata and connection failures. The [Mac browsing test] and [mobile grouping test] run those cases and read every PNG in the fixture directory. The Mac suite also sends those PNGs through the bridge helper when Pillow is configured.

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
[Frame metadata]: ../../../Apps/Frame/Sources/FrameKit/Services/ImageMetadataReader.swift
[Frame sidecars]: ../../../Apps/Frame/Sources/FrameKit/Services/SidecarReader.swift
[Remote client]: ../../../Apps/Frame/Sources/FrameKit/Services/RelayRemoteClient.swift
[Folder]: ../../../Apps/RelayBarMobile/Sources/MobileUI/FolderScreen.swift
[Screen]: ../../../Apps/RelayBarMobile/Sources/MobileUI/ReaderScreen.swift
[Reader]: ../../../Apps/RelayBarMobile/Sources/MobileCore/Reader.swift
[Document scheme]: ../../../Apps/RelayBarMobile/Sources/MobileCore/DocumentScheme.swift
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
[Folder listing]: ../../../Packages/AppComposition/Sources/PreviewSupport/FolderListing.swift
[PNG reader]: ../../../Packages/AppComposition/Sources/PreviewSupport/PNGTextReader.swift
[Image details]: ../../../Packages/AppComposition/Sources/PreviewSupport/ImageDetails.swift
[Connection failures]: ../../../Packages/AppComposition/Sources/PreviewSupport/ConnectionFailure.swift
[Browsing fixtures]: ../../../Packages/AppComposition/Sources/CompositionFixtures/BrowsingFixtures.swift
[Mac browsing test]: ../../../Apps/RelayBar/Tests/RelayBarTests/FrameRemoteHelperTests.swift
