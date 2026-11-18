# UI cut — first review

Date: 2026-10-22
Status: Review, not an accepted design. The reviewer did not receive the central keyboard monitor and incorrectly inferred that Space was unhandled. Its proposal to replace selection-while-previewing with favoriting keepers does not satisfy the full user request. Naming and interaction follow-up requested.

Read everything. Here is the review.

**1. Six harshest issues**

- **Four overlapping "bigger" states with five names.** The split preview has an "Enlarge" button, videos get a separate "Open video" button on top of it, double‑click and Return also enlarge. Inside the viewer, Return now means "Focus", the footer has a focus icon, the toolbar has "Full screen" that becomes "Toggle full screen", and Escape unwinds a chain of up to three states (`LibraryStore.swift:565`). A user cannot predict what Return or Escape will do from where they are. "Contact sheet" as a back button label is three syllables for "‹".

- **Select mode is a mode that lies about itself.** The button reads "Select" then "Done", with the help text "Select assets while previewing; Space toggles the current asset". The grid swallows Space outright (`ContactSheetWorkspace.swift:461`), and in the viewer Space plays video (`MainWorkspace.swift:168`), so the advertised key does not work in the grid and conflicts on videos. Arrows silently stop changing selection. Plain click toggles without Cmd, unlike every other Mac grid. The bar then prints "3 selected" plus "Viewing x.jpg" to explain the split the mode created. In Focus the action bar is hidden and the trash icon deletes the checked set, not the image on screen. That is the one place a user will delete the wrong files.

- **Vocabulary churn.** "9 assets", "Show all files", "Select a file", "No media", "All assets are favorited", "Deleting · 3 / 10", "Move to Trash 1" in source versus "Move 1 to Trash" in the fixture. "Original / Loading… / Original loaded" is a button whose label is a status report. "Partial" is a warning with no noun. "Scan Again", "Retry", "Refresh Folder", "Refresh to retry" and the toolbar ⟳ are five spellings of one action.

- **Heart versus star.** Grid cells draw "★" (`ContactSheetWorkspace.swift:506`), the filmstrip draws a yellow star, the action bar uses `star`, the fixture filter is a star outline, and Focus mode uses a heart (`MainWorkspace.swift:201`). The empty state uses a star icon. The user thinks "heart". The app cannot decide, so the filter name cannot be understood either.

- **Redundant chrome.** The toolbar shows the root name and the full path on two lines while the sidebar tree and the metadata "Path" row show the same thing. "JSON" appears as a cell badge, a pill in the preview header, a section label "Paired JSON · raw data", and a caption "From paired JSON · not embedded". The grid header spends a second row on "Include subfolders". "Size" labels a slider that visibly resizes thumbnails. "Open…" exists in the toolbar and the welcome view, then the chooser adds "Choose Folder…", "Browse in RelayBar…" and two instruction sentences.

- **Confirmation and undo are inconsistent with the stated policy.** Local multi‑delete and Archive still pop a three‑sentence alert (`LibraryStore.swift:755`) even though local Trash has Undo. Remote delete has none. "Undo Trash" is shown in the action bar, the notice and the Focus footer at once. Export is disabled for more than one item with a help string that explains the limitation instead of removing it. The filter picker is a label‑less popup reading just "All" beside "9 assets", and the segmented version in `ScopeBar` is dead code (`MainWorkspace.swift:120`).

**2. DELETE / RENAME / KEEP**

DELETE
- "Select" / "Done" button, `isSelecting`, "Viewing x.jpg", "Toggle selection (Space)" footer button.
- "Focus" state and its footer icon. "Full screen" / "Toggle full screen" toolbar text. "Open video" overlay button. "G" shortcut.
- Toolbar second line (full path). "Contact sheet" title and subtitle in the fixture.
- "JSON" pill in preview header, "From paired JSON · not embedded", "From embedded metadata". Keep one cell badge.
- "Size" label. "Include subfolders" row. "N folders" scan counter.
- "Original / Loading… / Original loaded" button. Load the full file automatically when the viewer opens on one image. Never for the grid.
- Local batch confirm alert, Archive confirm alert, "Undo Trash" button in the bar and Focus footer. Keep ⌘Z and the "Undo" link in the notice.
- "1 selected" when one item is selected. "Select a file", "Metadata" placeholders. Empty stage says nothing.
- "Reconnect the drive, or locate this folder to keep its favorites.", "Refresh to reconcile this folder with Finder.", "Favorite a file with F while viewing it.", "In RelayBar, choose Open in Frame.", "Export exact copy, replacing destination metadata", "Select one asset to export; paired JSON is included".
- Per‑section copy icons except on Generation.
- "Folders" sidebar header.

RENAME
- Noun: "assets" → "items" everywhere counts need a noun. Drop the noun where the context is a grid: "9".
- "Favorite" / "Unfavorite" → "♥ Favorite" with the heart filled when all targets are favorites. Heart is the only glyph. Star goes.
- Filter: "All · Favorites · Not favorited" → segmented text control **All · Favorites · Others**. Icon‑only is not clearer: a filled heart reads as "favorites", but an outline heart reads as an unpressed toggle, not as "everything else". "Not favorited" fails because it negates a participle. "Unfavorited" implies removal. "Rest" reads as pause. "No heart" ties a label to a glyph. "Others" is the plain complement and needs no new database.
- "Move to Trash 1" → "Move to Trash" local, "Delete" remote. Count lives once on the left of the bar.
- "Archive 1" → "Archive". "Restore 1" → "Restore".
- "Enlarge" → ⤢ icon only, since double‑click and Return do the same.
- "Contact sheet" back button → "‹".
- "Partial" → ⚠ icon that opens the issue text with one "Retry" button. "Scan Again", "Refresh Folder" → "Retry" or ⟳.
- "File unavailable. Refresh to retry." and "This file is no longer available" → "File missing" with ⟳.
- "Studio is unavailable" → "Can't find Studio" + "Locate…".
- "Remote folder unavailable" → keep, buttons "RelayBar" and "Retry".
- "Archive is empty", "No favorites", "All assets are favorited", "No media" → one message "Nothing here" with "Show all" when filtered. Keep the formats line on the unsupported‑media case.
- "Embedded metadata · 9 fields" → "All fields (9)". "Paired JSON · raw data" → "JSON" with filename. "File size" → "Size". "Generation" sections: one section, suffix "JSON" or "Embedded" only when both exist.
- "RECENT FOLDERS" → "Recent". "Remove recent shortcut" → "Remove from Recents". "Choose Folder…" → keep. "Open folder…" fixture → "Open…".
- "Moved 3 assets to Trash · 1 not processed" → "3 moved to Trash · Undo". "3 deleted".
- "Deleting · 3 / 10" → "Deleting 3 of 10".

KEEP
- Sidebar tree, parent arrow, "Archive" row at the bottom.
- Thumbnail slider, filmstrip, split preview + metadata.
- Cell checkmark for selected, thick ring for current.
- F, ⌫, ⌘A, Return, Escape, ⌃⌘F.
- Per‑file failure sheet.

**3. Selection and preview flow**

Standard Mac selection, no mode.

- Click selects one and previews it. Cmd‑click toggles and previews the clicked item. Shift‑click extends the range and previews the clicked item. Drag marquee selects. ⌘A selects all.
- Arrows move selection and preview together. Shift‑arrows extend. Clicking blank space clears.
- The preview always shows the current item, which is the item with the thick ring. Selected items show the checkmark. Nothing else is needed to show what Delete will act on: Delete acts on every checkmarked cell. The left of the bar says "3 selected".
- Double‑click or Return opens the viewer on the current item. Arrows in the viewer move the selection to one item, same as the grid. Delete in the viewer deletes the image on screen, then shows the next survivor. The viewer never deletes multiple.
- ⌫ in both places. No alert. The number on the bar is the confirmation.
- F toggles the heart on the selection. The review workflow for "select images to delete while previewing" is: heart keepers in the viewer with F, Escape, pick "Others", ⌘A, ⌫. This is the filter request doing the job Select mode was invented for.

The one unavoidable choice: either arrows always move selection, or there is a way to look at an item without selecting it. The second requires a mode or a modifier, and every version of it reintroduces "selected versus viewing". Take the first. Marking for deletion is done with the heart, not with a parallel selection.

**4. Proposed layout**

Toolbar: `[▯] [Open…]   Studio › Photos        [⟳]`. In the viewer: `[‹] [Open…]   Studio › Photos        [⟳]`.

Grid header, one row: `9   [All | Favorites | Others]   [✓ Subfolders]   [━━●━━]`. Scanning: spinner, "Stop". Incomplete: ⚠.

Preview header: `north-coast.jpg                       [⤢]`.

Action bar: `3 selected                 [♥ Favorite] [Export…] [Archive] [Delete]`. Count hidden at 1. Remote shows "Delete", local shows "Move to Trash". During work: `Deleting 3 of 10  [Cancel]`.

Metadata panel:
- FILE: Type, Dimensions, Size, Created, Modified, Path.
- GENERATION with copy icon: Prompt, Negative, then rows. Header suffix "JSON" or "Embedded" only when both sources exist.
- CAPTURE or VIDEO rows.
- `› JSON  north-coast.json` disclosure.
- `› All fields (9)` disclosure.

Viewer: image, filmstrip below, metadata panel right. Footer: `north-coast.jpg      ‹ 3 / 9 ›`. ⌃⌘F is system full screen and hides filmstrip and metadata. Escape closes.

**5. Priority**

1. Remove Select mode and Space toggling. Delete targets the selection. Fix the Focus‑mode trash icon now, before any other polish, since it is the wrong‑file deletion path.
2. Collapse Enlarge, Focus and Full screen into viewer plus system full screen. One meaning for Return and Escape.
3. Replace the filter popup with the segmented text control, and switch every star to a heart.
4. Remove the local confirm alerts and the duplicate Undo buttons.
5. Vocabulary pass with "items" and the labels above.
6. Strip the toolbar path line, JSON triplication, "Size" label and the subfolders row.

Backend fixes in the task spec do not change this list. Stable thumbnails after delete make the grid feel right, but none of the six issues above are backend.
