# Frame 2.0.0 Beta 3 verification

Published November 18, 2026 Pacific time as a GitHub pre-release. The annotated tag `frame-v2.0.0-beta.3` resolves to `1617701d666d53dd384cfc2583e76c87f68db9b0`. GitHub continued to list RelayBar 1.6.0 as its latest stable release. [Release notes](https://github.com/lx2026/RelayBar/releases/tag/frame-v2.0.0-beta.3)

| Artifact | Verified value |
| --- | --- |
| Application | Frame 2.0.0, build 23, `com.lx2026.Frame`, bridge v7 |
| Supported Macs | Apple silicon and Intel, macOS 14.0 or later |
| Download | [Frame.zip](https://github.com/lx2026/RelayBar/releases/download/frame-v2.0.0-beta.3/Frame.zip), 7,221,993 bytes |
| SHA-256 | `a1b4459bb33a3ffb7c64e673979c282a0899f7447cb332533c9aa480247b4fd9` |
| Apple notarization | Accepted, `5c4eb514-16e0-412d-9c9c-3cb670cec6ba` |

The 17 release-script tests passed. The native Frame suite and the x86_64 suite under Rosetta each ran 238 tests with 3 skipped and zero failures. SwiftPM's filter helper initially tried to load the Intel test bundle into an arm64 process. Running the full bundle with the Intel XCTest runner passed. A universal warnings-as-errors Release build passed.

Both the candidate and the anonymous GitHub download passed clean-extraction checks for metadata, both CPU slices and deployment targets, dSYM UUIDs, production entitlements, timestamped hardened-runtime signature, stapled ticket, Gatekeeper assessment, renderer resources and licenses. The downloads matched byte for byte and GitHub reported the same digest.

On macOS 27.2.1, closing the notarized library window left the process running with zero visible windows. Opening that bundle in Finder restored one library window in the same process. ⌘Q exited. A fresh extraction of the public asset also launched, displayed a window and quit normally. The [window-reopen](../task-specs/archive/073-frame-window-reopen.md) and [stalled-preview](../task-specs/archive/074-frame-document-quit.md) records cover the selected-note, Settings and unresponsive-WebKit cases.

The reported Icons-mode freeze in a large notes folder remains open. This release was tested on Apple silicon, including Rosetta. Physical Intel and macOS 14 runs remain outstanding.
