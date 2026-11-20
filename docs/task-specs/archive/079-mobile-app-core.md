# Task 079: Mobile app core

Status: Complete
Design: [RelayBar for iPhone and iPad](../../designs/relaybar-ios.md)
Verification: [record](../../verification/077-083-relaybar-mobile.md)
Depends on: Tasks 077 and 078

## Outcome

An iPhone app connects to a host on the tailnet, opens on Continue Reading, browses folders, and reads Markdown, images and text rendered as on the Mac.

## Delivery Boundary

Included: `Apps/RelayBarMobile`, its tests and a new system spec.

Excluded: web services and port handling in Open Location (Task 080); iPad layouts, video, HTML files, the Plugins screen, share and download, and delete (Task 081); release work (Task 082).

## Work

1. Structure: a Swift package holding features, stores and SwiftUI views, with logic targets that also build and test on macOS, and `RelayBarMobile.xcodeproj` with one app target for iOS 27 on iPhone and iPad. It depends only on the repository's packages.
2. Composition: one runtime. Root features for profiles, trust, keys, registries (page kinds, location resolvers, preview formats, start-page sections, file actions) and scene demand. A realm per host with `session`, `files` and readers. A plugin catalog with Favourites, Prompt Search, Data Saver and Paper Appearance.
3. Stores: host profiles and reading history in a versioned preference document. Pinned host keys in a trust store. The device key is created in the Secure Enclave on first need. A password, if kept, is a this-device-only Keychain item. No secret enters the preference document.
4. Screens: Hosts, First Connection, Home, Folder, Document and Image, following the design's main path, with the house palette, status marks that differ by shape, 44-point targets, Dynamic Type, VoiceOver labels, and light and dark appearance.
5. Reading: Markdown through `MarkdownRendering` in a web view, with a scheme handler that serves relative assets from the document's folder. Outline, Rendered and Source, the changed-since-opened mark, and reading position restored by heading and then offset. Image details from PNG text, EXIF and sidecars. Text and JSON within their limits.
6. Cache: keyed by profile, account, host-key fingerprint and path; revalidated on reopen; purgeable; cleared per host.
7. Lifecycle: sessions are withdrawn when the last scene leaves the screen and reconnect on return. A cached document stays readable meanwhile. An unreachable host shows the design's message.
8. Demo host: a launch argument swaps in an in-memory host with a bundled sample workspace, through the same protocols a real host uses.
9. Screen gallery: a headless run renders each screen with the demo host, in light and dark, to image files under `.build/`.

## Acceptance

- `xcodebuild` builds the app for the iOS Simulator SDK with warnings as errors and no simulator booted.
- Logic tests pass on macOS: stores, history, cache keys and revalidation, and the composition tree.
- Composition tests show a realm appearing on demand, a lost session clearing its dependents and a recovered one restoring them, and no feature identifier in any stored document.
- Reader tests show the shared Markdown fixtures producing the Mac's HTML, a relative image resolving through a fake file service, and a reading position surviving a round trip.
- A headless end-to-end test drives the feature layer against the test `sshd` from Task 078: add a host, trust its key, list a folder, open a Markdown file, restart, and get that document from Continue Reading.
- The gallery writes one image per screen in each appearance without opening a window, and the registries are filled by features, so removing a plugin removes its entries.
- The mobile tests run from `scripts/test.sh` and CI.
- `docs/verification/` holds a device checklist marked not yet run.
- `docs/system-specs/modules/mobile-app.md` describes the implemented behaviour.
