# Frame reader layout

Status: Implemented — 2026-11-16. Automated checks pass; [verification](../verification/068-frame-reader-layout.md). Awaiting the owner's hand check in the real app.

## Outcome

Frame opens as a two-column reader for folders of mixed files: a regular file tree on the left, the selected file on the right with nothing else in the way, a switch to a thumbnail view of the folder, and aids for reviewing generated documents. Documents get the same care as images.

## Delivery Boundary

Frame only. RelayBar, the bridge protocol, the shared packages, stored favourites and archive data, the Open sheet, Settings, the Plugins window and the app icon do not change. No version change, install, push or release.

## Work

- Window: two full-height columns with one dividing line and no bar across the window; the window controls sit in the left column's top row.
- Left column: a Files/Icons switch; search; one tree of folders and files with compact rows, a favourite marker, and library actions on the root row; a footer with the kind filter, favourites only and Archive.
- Right column, Files mode: one top row with the file's name and kind, previous and next with the position, Favorite, Archive, Move to Trash and a menu for the rest. The file fills the remainder: documents in a reading column, images and video centred with a details rail for generation data and the sidecar.
- Right column, Icons mode: the selected folder as a grid with folder tiles and thumbnails that suit each kind, kind chips, Subfolders, Select and size. Actions for the selection appear in the top row. Opening an item returns to Files mode.
- Sidecar files are folded into the file they describe unless Show Sidecar Files is on.
- The bottom selection bar and the Preview/Grid switch go away; everything they offered stays reachable.
- Review aids: a Rendered/Source switch for Markdown and HTML; an "On this page" outline for Markdown that follows the section being read; a marker on files changed since they were last opened.
- Every scroll view in the window uses the overlay indicator.

## Acceptance

- Captures at 1280 × 800 in light and dark of Files mode with a Markdown file, an HTML file and an image, of Icons mode, and of the empty state match the chosen mock in layout and proportion.
- Every command that existed before is still reachable by pointer and keeps its shortcut; a list in the verification record maps each old control to its new place.
- A Markdown file with several headings shows its outline, the outline follows scrolling, and choosing a heading scrolls to it; Source shows the file's text.
- A file gains the changed marker when it is modified after it was last opened and loses it when opened; files present before this build first opened the library carry no marker.
- With "Show scroll bars" set to Always, nothing is cut off and no scroll view shows the wide scroller.
- `scripts/test.sh`, the Frame build with warnings as errors and `git diff --check` pass; the Frame system spec describes the new behaviour; a verification record lists what changed and what still needs a hand check.
