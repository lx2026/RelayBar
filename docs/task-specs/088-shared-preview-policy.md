# Task 088: One definition for file types, limits, palette and wording

Status: Complete
Ledger: [UX parity](../system-specs/shared/ux-parity.md)
Depends on: Task 087

## Outcome

RelayBar, Frame and the mobile app read their file-type lists, size limits, reader palette and shared wording from `Packages/AppComposition`, so a change to any of them reaches all three apps at once.

## Delivery Boundary

Included: `Packages/AppComposition`, `Apps/RelayBar`, `Apps/Frame`, `Apps/RelayBarMobile`, the ledger and `scripts/parity.py`.

Excluded: folder order, hidden entries, PNG text reading and its limits, image detail labels, connection error wording and outline tracking (Task 089). No change to stored data, the bridge wire format, release versions or build numbers.

## Work

1. **Home for the definitions.** Extend the shared preview registry, or add one small target beside it with no interface dependency, that FrameKit, RelayBar and MobileCore all import. Do not add a second registry alongside an existing one.
2. **File types.** One table gives each kind its extensions: Markdown is md, markdown, mdown and mkd; images are JPEG and PNG; video is mp4, mov and m4v; HTML is html and htm. Every app opens, labels and groups files from this table. WebM is not listed as video.
3. **More image formats.** BMP, GIF, HEIC, HEIF, TIFF and WebP come from one plugin, defined once and on by default in all three apps. With it off, those files are listed as other files.
4. **Limits.** One value each, used by every app: a document (Markdown, HTML or text) is 10 MiB; an HTML page asset is 32 MiB, a page's assets together 64 MiB and 128 distinct requests; an image or other original is 100 MiB; a remote listing is 10,000 entries; companion text is up to 32 files, 2 MiB each and 256,000 characters together. The numbers inside the remote helper script are filled in from these values, not typed again. RelayBar's JSON and video limits stay where they are.
5. **Reader palette.** The paper palette for rendered Markdown and plain text is defined once, for light and dark. RelayBar's Markdown preview adopts it. Frame and the mobile app delete their copies.
6. **Wording.** Keeping a folder, file or website is Pin and Unpin with the pin glyph; Frame's Favorite and heart are replaced in every label, menu, tooltip and accessibility label, and its stored favourites still load. A web service a person opens is a Website: RelayBar's Service Labels plugin and its related text use that noun, while a forwarded port stays a tunnel.
7. **Website names.** Product recognition, the title fallback and their limits move to the shared package; RelayBar and the mobile app use it.
8. **Plugin text.** A plugin offered by more than one app takes its name and description from one definition.
9. **Checks.** The mobile Markdown reference test covers the palette. Shared tests cover the file-type table, the image plugin switch and the limits. Update the ledger rows, the inventory and `scripts/parity.py` if its counting needs it.
10. **Specs and notes.** Update the affected system specs, and add a short note of the visible changes to each Mac app for its next release notes.

## Acceptance

- `./scripts/test.sh parity` reports at most 7 rows to fix and at most 20 definitions outside the shared package, with fixture coverage still complete.
- A file named `notes.mkd` opens as Markdown in all three apps; a `.webp` image opens in all three with the plugin on and is listed as another file with it off.
- RelayBar's Markdown preview and Frame's reader produce the same palette rules, checked by a test.
- Frame shows Pin and Unpin where it showed Favorite, and a profile saved before the change keeps its pinned items.
- `./scripts/test.sh all` passes with warnings as errors, the mobile app builds for the iOS SDK, and `git diff --check` is clean.
