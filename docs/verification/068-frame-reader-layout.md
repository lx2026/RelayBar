# Task 068 — Frame reader layout

Date: 2026-11-16. Implemented in the working tree; not committed. A notarized Frame 2.0.0 (18) built from this tree is verified but not installed, because the catalog could not be backed up first (see [Local installation, build 18](#local-installation-build-18)); Frame 2.0.0 (17) remains installed. Nothing has been run in the real app: every check below comes from unit tests, builds, and captures of the separate debug verification build (`com.lx2026.Frame.workspace-verification`) with a synthetic library.

## What changed

- The window is two full-height columns with one hairline between them and no bar across the window. The window controls sit in the middle of the library column's 52-point top row. The column defaults to 260 points, stays between 200 and 420, and keeps its width under the existing autosave name.
- Library column: a Files/Icons switch and the hide-folders button; the search field ("Search", Command-F, "N of M" while a search narrows the list); the existing tree, restyled with 26-point rows, kind icons, accent selection and a heart on favourites; a root-row pull-down with Open…, Parent Folder and Refresh; a footer with the kind filter, favourites only and Archive.
- Files mode: one top row with the name, a kind chip, Rendered/Source for Markdown and HTML, Previous, the position, Next, Favorite, Archive, Move to Trash and More. Documents fill the column (an HTML page as a white card); an image or video sits beside a 240-point details rail. The old Info panel is gone.
- Icons mode: the folder's name and count, kind chips, Subfolders, Select/Done and the size slider, then the selection's actions. Subfolders come first as folder tiles; documents are drawn as pages with a kind chip, videos carry their duration, files with sidecars a `{ }` chip.
- Sidecar files are folded into the file they describe unless Show Sidecar Files is on; every operation still carries them.
- The toolbar, the bottom selection bar and the Preview/Grid control are gone. A file operation's progress and Cancel appear in a strip at the bottom of the reader column; toasts stay.
- Every scroll view in the window uses the overlay scroller.

The Frame system spec, [frame-viewer.md](../system-specs/modules/frame-viewer.md#window-layout), describes the behaviour in full.

## Old controls and their new places

| Before | Now |
| --- | --- |
| Toolbar Open… | Root-row pull-down; File › Open… (⌘O); Open… in the empty window |
| Toolbar Refresh | Root-row pull-down; Refresh Folder (⌘R) |
| Sidebar Parent Folder (remote) | Root-row pull-down; Parent Folder (⌘↑) |
| Sidebar toggle | Hide folders in the library column; Show folders in the reader's top row |
| Preview \| Grid | Files/Icons switch; Contact Sheet (G) |
| Toolbar search field and match count | Library column; "N of M" inside the field; Search Prompts (⌘F) |
| File-type and favourites menu | Footer kind pop-up and heart; kind chips in Icons mode |
| Sidebar Archive | Footer Archive, shown selected while active |
| Select / Done | Icons top row; Files top row while selecting |
| Info toggle and Info panel | More › Hide/Show Details; the details rail; the outline for Markdown |
| Full-screen button | More › Full Screen (⌃⌘F) |
| Document Back / Forward | More › Back / Forward |
| Original (remote image) | More › Original |
| Preview pane's open-viewer button | Double-click, Return, Open Viewer (Return) |
| Bottom bar Move to Trash N / Delete N | Top-row Trash, labelled the same, with "N selected" |
| Bottom bar Favorite | Top-row heart (F) |
| Bottom bar Export… | More › Export Exact Copy… (⇧⌘E) |
| Bottom bar Archive / Restore | Top-row Archive / Restore |
| Bottom bar progress and Cancel | Strip at the bottom of the reader column |
| Viewer bar Previous, position, Next | Files top row ("6 of 11") |
| Contact-sheet header count, Subfolders, slider | Icons top row |
| Open in Default App (document error row) | Still in the error row; also More › Open in Default App |

## Review aids

- **Rendered and Source.** A two-part switch after the kind chip, for Markdown and HTML only. Source shows the file's own text through the existing plain-text path, monospaced and wrapped. It starts as Rendered and holds while the app runs.
- **On this page.** For Markdown read rendered: a 200-point rail beside the article with the second- and third-level headings (third level indented), the section being read marked by the accent line and semibold text, and under them the file's path within the library and its modified time. It follows scrolling; choosing a heading scrolls to it. It is hidden with fewer than two such headings, when the column cannot hold the 680-point article and the rail, and after Hide Details. The headings come from Frame's own script in WebKit's isolated client world, which posts to a handler registered only in that world. The page world, its script and content policies and its existing script are unchanged; a test confirms the page sees neither the script nor the handler.
- **Changed since last opened.** A 6-point accent dot ("Changed since last opened") on tree rows and tiles. Only file times are compared, never the Mac's clock. The first time a folder is listed, the newest modification time among its files becomes its baseline, so nothing present then is marked. A file counts as opened only when it is the file displayed in Files mode; its modification time at that moment is recorded. A later modification marks it again. Baselines and opened times are two new models in the same catalog as the favourites, keyed the same way. An entry is dropped only when a fresh listing of its own folder lacks the file; files Frame moves to the Trash or the Archive keep their entries. Remote libraries use the listing's ISO 8601 times.

## Captures

Produced with `.build/task-068-design/tools/capture.sh all,extra` (git-ignored). The script builds the verification bundle from the working tree, runs it against a synthetic library in a throwaway home with a capture helper injected, and writes 1280 × 800-point windows in both appearances to `.build/task-068-design/`. Eight are kept here at window size:

- [Markdown with its outline](assets/068-frame-reader/markdown-outline-light.png) and [in dark](assets/068-frame-reader/markdown-outline-dark.png)
- [Source for the same file](assets/068-frame-reader/markdown-source-light.png)
- [HTML](assets/068-frame-reader/html-light.png)
- [Image with the details rail](assets/068-frame-reader/image-light.png)
- [Icons](assets/068-frame-reader/icons-light.png) and [with three selected](assets/068-frame-reader/icons-selection-light.png)
- [Two files with the changed marker](assets/068-frame-reader/changed-markers-light.png)

The helper draws the window as the key window of the active app, because the capture runs while another app is frontmost. Where an HTML page meets its card, the captured page snapshot covers the card's one-point border.

## Acceptance

| Criterion | Evidence |
| --- | --- |
| Captures at 1280 × 800, light and dark, of Files mode with Markdown, HTML and an image, of Icons mode and of the empty state match the mock | All present in `.build/task-068-design/` and compared with the mock: column widths, 52-point rows, insets, tree and tile geometry, rail and outline. Icons mode uses the default thumbnail size, so it shows six columns where the mock shows five. |
| Every command still reachable by pointer, with its shortcut | The table above. The main-menu commands and their shortcuts are unchanged; Search Prompts now also shows a hidden folders column or leaves the full-screen viewer first. |
| Outline follows scrolling, choosing a heading scrolls to it, Source shows the text | `ReviewAidsTests`: the outline from a real WebKit page, the active heading after choosing one, the page world unable to see the script, Source showing `## Part 1` as text. Captures 01 and 10. |
| Changed marker rules | `ReviewAidsTests`: nothing marked at first listing, including files whose times are ahead of this Mac's clock; marked after a later change; only the displayed file is recorded; marked again after another change; entries survive Trash and Undo, Archive and Restore, and a whole-library scan that skips a package; dropped when a folder listing lacks the file; no markers without the new models. Captures 11 and 12. |
| No wide scroller and nothing cut off with "Show scroll bars" set to Always | Native scroll views keep the overlay style and set it again on the preference-change notification; a capture run with the setting forced to Always for the app reported overlay styles and a document with no scroll-bar gutter. Not yet seen with the System Settings switch. |
| Checks, system spec, verification record | `./scripts/test.sh frame`: 9 script tests; 214 Frame tests with 2 skipped; no failures; no test window appears on screen. `swift build --package-path Apps/Frame --product Frame -Xswiftc -warnings-as-errors` succeeds; `git diff --check` is clean. The system spec and this record are updated. |

## Catalog upgrade

`CatalogUpgradeTests` writes a catalog on disk with the schema as it was before this task (recent folders and favourites only), including a favourite of an archived item, then opens the same file through `FrameCatalogStore.open`, which the app uses at launch. Every row and value is intact, the two new models are empty and usable, and both survive reopening. The app has no versioned schema or migration plan; SwiftData adds the new tables when it opens the store. If the catalog cannot be opened, the app stops at launch with "Could not create Frame catalog" and leaves the store file untouched; nothing deletes or replaces it.

## Review

An independent read of the diff found nine defects, all fixed with tests where they can run without the app:

1. In Files mode with Select on, Archive and Trash reached every checked file with no count on screen. The Files row now shows "N selected" like the Icons row, and Trash keeps the old bar's wording.
2. Switching to Files mode marked the previous selection as opened. Only the file the window displays is recorded now.
3. Markers compared the Mac's clock with a remote host's file times. Baselines now come from each folder's first listing and opened times are file times.
4. Pruning treated "not in this listing" as gone, so Trash and Undo, Archive and Restore, and package contents skipped by the whole scan lost their entries. Only a folder's own listing drops entries, and files Frame moved keep theirs.
5. Leaving full screen with the green button left the window without the folders column and with the window controls over the file name. Leaving full screen now ends the full-screen viewer; see [After the hand check](#after-the-hand-check).
6. Sidecar rows depended on the remote folder cache. They are built from the file's own companion list.
7. Kind counts and the folder count were recomputed on every update, and listing times parsed on every check. Both are cached.
8. Command-F did nothing in the full-screen viewer or with the folders column hidden. It now brings the field into view first.
9. Turning Show Sidecar Files off while a sidecar was on show jumped to the folder's first file. It now shows the sidecar's owner.

## After the hand check

The owner reported that, in the installed build with the old layout, buttons such as the folders toggle stop responding after leaving full screen. Before on-screen testing was stopped, the new build did not show it: in the verification build, 103 checks passed twice after leaving full screen by the green button, after the full-screen viewer was left by Escape, by Control-Command-F and by the green button, after hiding and showing the folders column in full screen, and at the minimum window size. Each control's centre hit-tested to the control, each click took effect, and the window controls were back in the top row. Both suspects are now ruled out by construction. The full-screen viewer ends whenever its window leaves full screen, closes, or has not entered it within three seconds. The title bar is kept no wider than the window controls, and its placement is re-applied after every exit and every rebuild of its views. `FullScreenTests` cover both on a window that never appears, by posting the window's own notifications. A real full-screen round trip on the owner's Mac remains a hand check; the scenario is kept as `DRIVER=fullscreen.py FRAME_ON_SCREEN=1 .build/task-068-design/tools/capture.sh fs`, which takes over the screen and runs only when asked.

Frame's tests no longer show anything: every test window is a `QuietWindow`, placed far off every screen, never key or ordered in front, and the test process cannot activate itself. The capture tooling is quiet by default: the verification app runs as an agent that never activates, its window stays off screen and real full screen is refused; `FRAME_ON_SCREEN=1` opts back in. The quiet capture mode has not been run yet.

## Still to check by hand

- Window controls stay centred in the top row through resizing, entering and leaving full screen (green button and Control-Command-F, left by Escape, by the same command and by the green button), a second window open, and sleep; the folders toggle, the mode switch, More and Previous/Next respond after each.
- The divider drags between 200 and 420 points, keeps its width after relaunch, and shows the resize cursor.
- The root-row pull-down, More, the kind pop-up, the chips, Select/Done, and Return or double-click on folder tiles.
- The outline following trackpad scrolling, choosing headings, and hiding when the window narrows.
- Markers on a real library and on a remote library through RelayBar, including after Trash and Undo.
- "Show scroll bars" set to Always in System Settings: tree, grid, rail and document.
- The operation strip and Cancel during a long Trash; toasts with Undo.
- Video playback and its controls; remote states (connecting, unavailable, Retry).
- VoiceOver on tree rows, tiles, the changed marker and the mode switch.

## Left for the owner

- Frame's icon is not chosen. The Open sheet, Settings and the Plugins window are unchanged.
- Frame sets the overlay scroll-bar default for its whole process, so Settings, Plugins and alerts also use overlay scrollers whatever the system setting.
- The window-control placement adjusts title-bar views that AppKit owns; resizing, full screen and a second window need the hand check above.
- Hide/Show Details for a Markdown file controls its outline; HTML and text files show the details rail only after Show Details.
- The default thumbnail size gives six columns at 1280 points where the mock shows five.

## Final gate

After the review fixes the whole repository was checked together with the RelayBar scrolling fix: 9 script tests; 94 shared tests with 3 skipped; 450 RelayBar tests with 31 skipped; 210 Frame tests with 2 skipped; no failures. The Frame build with warnings as errors, the unsigned RelayBar Release build and `git diff --check` pass. Log: `.build/task-068-gate-rerun.log`.

The first attempt at this gate stopped at one shared-package test, `BridgeLifecycleTests.testPeersThatHangUpAtOnceCannotRaiseSIGPIPEAndTheServerKeepsAnswering`, in code this task did not touch. It then passed in three isolated runs and in the repeated gate, so it is recorded here as a timing flake and was not changed.

## Local installation, build 18

The owner approved building, notarizing and installing Frame 2.0.0, build 18, with RelayBar 2.0.0, build 24, for a hand test. The source was the uncommitted working tree on top of commit `a896188`; the only change made for this build raised the build number from 17 to 18 in `Apps/Frame/AppBundle/Info.plist`, the only place Frame sets it. The 9 release-script tests and the property-list and entitlements lint passed; the app suites were not rerun because they passed on this tree the same day and only build numbers changed.

- Apple submission `4fd3bef8-564a-444e-92cf-ec6c1c588e12`: Accepted, status code 0, no issues; team `39HYFR5Z65`, profile `AC_NOTARY`.
- Final ZIP SHA-256, after stapling: `f55511a6066c7128a24334506bc841ffbe1207e4e1c590504d0dcb72ad8e33ec`.

The clean extraction of the final ZIP passed: strict deep signature; Developer ID, hardened runtime and timestamp; entitlements equal to `Apps/Frame/AppBundle/Frame.entitlements` (sandbox, App Group, network client, bookmarks, user-selected files); stapled ticket; Gatekeeper as Notarized Developer ID; arm64 and x86_64; version 2.0.0 and build 18; matching dSYM UUIDs for both slices; renderer bundles, the two GitHub themes, the Latin Modern font and metrics, and the licence texts. The icon is byte-identical to `Apps/Frame/AppBundle/Resources/AppIcon.icns` in the working tree and differs from the icon at `a896188`; by eye it is the dark body with four light corner brackets around an amber dot.

**Not installed.** Build 18 adds two tables to the catalog, so the catalog was to be copied before its first launch. The catalog is not in Frame's own sandbox container. Frame opens SwiftData's default configuration, and because the app has an App Group entitlement that configuration keeps `default.store` and its `-wal` and `-shm` files in the shared `39HYFR5Z65.FrameRelay` group container, under `Library/Application Support/`. macOS refused to let the installing session read files there ("Operation not permitted"), so no copy was made, and the originals were neither opened nor changed. Frame was therefore not replaced, quit or launched; 2.0.0 (17) remains installed. Frame has not opened its catalog with build 18.

The installed 2.0.0 (17) is already archived to `.build/local-notarized-install-2.0.0-rb24-frame18-2026-11-16/backups/Frame-2.0.0-build17.zip`, which extracts and passes signature, ticket and Gatekeeper checks. The verified build 18, its dSYM, logs and Apple's records are in the same folder. Installation waits for the three store files to be copied, with Frame quit, into `backups/frame-catalog/` there. No commit, push, tag, release, feed, website or Homebrew change was made.
