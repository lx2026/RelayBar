# Design review — round 1

Date: 2026-10-22
Input: review brief and two synthetic installed-UI screenshots.
The preceding attempt was denied file access and produced no critique. This successful retry inspected both images.

Screenshots inspected: paired-json-light.png (full workspace at 1280×800pt equivalent, light mode) and remote-first-use.png (the RelayBar sheet). Both are synthetic fixtures. Nothing else was read.

## Five most important usability risks in the candidate

1. **Four columns at 1280pt starve the grid.** Rail 180 plus side-by-side preview and metadata leaves roughly 500pt for the contact sheet, about three tiles at the current size. The screenshot's real problem is not stacking. It is that the inspector is a narrow 310pt column and the grid wastes 700pt. Forcing preview and metadata side by side at 1280 trades one squeeze for another, and a 220 to 260pt metadata column will wrap every prompt and path.

2. **"Previewing X · N selected" keeps the preview/selection split alive.** The screenshot shows "Not selected" over a live preview, and the candidate still allows the previewed item to differ from the set Trash acts on. If X is not in the selection, Trash deletes things the user is not looking at. The active item must always be a member of the selection, and the count in the action row must be the only count the user sees.

3. **Archive as a scope segment next to All and Favorites.** Archive is a location with different verbs. Favorites is a filter. Putting them in one segmented control (as the screenshot does) is what produced "archive mixed with filtering". Swapping the Archive button for Restore inside that scope is a hidden mode change. A user who filtered to Favorites and then clicked Archive will not know whether archived favorites are now gone or just hidden.

4. **One rail for recents, remote paths and the current folder's children.** Three list types with different semantics share 180pt. History items and hierarchy items look identical, names truncate at about 20 characters, and the rail collapses at exactly the width where the user needs it most. That reintroduces "hidden location switching", the top pain point. The current screenshot also has an unlabeled purple toolbar button, which is presumably the remote toggle. The candidate does not say where that goes.

5. **Remote first use is still a blocking cross-app round trip.** The sheet repeats the instruction three times, truncates the first line, shows an empty list with no explanation, and offers Retry before anything has failed. "Continue in RelayBar" as one button is better, but a modal sheet still hides the workspace while the user is in another app. When they return, Frame must show changed state without a click. If nothing changed, Retry means "I did not understand", not "try again".

## Recommended arrangement

Use width rules, not breakpoints. The inspector stacks when it is narrower than 640pt and goes side by side only above that. This avoids a layout flip when the rail collapses.

**1280×800, rail open (default after first run)**

| Region | Width | Notes |
|---|---|---|
| Rail | 180 | Three labeled sections: Recent, Remote (RelayBar), This folder. |
| Contact sheet | 560 | Four tiles at 128pt. Slider and count in its own header row. |
| Inspector | 540 | Preview on top at ~300pt tall, metadata below with ~380pt. |

**1280×800, rail collapsed**

| Region | Width | Notes |
|---|---|---|
| Contact sheet | 600 | |
| Inspector | 680 | Side by side: preview 420, metadata 260, user-resizable. |

Toolbar keeps a path control showing the current location at all times, so collapsing the rail never hides where the user is. The path control truncates in the middle, not the end, and tooltips show the full path.

**960×640**

| Region | Width | Notes |
|---|---|---|
| Rail | collapsed | Reopen from a toolbar button or Command-Option-S. |
| Contact sheet | 460 | Three tiles at 128pt or four at 100pt. |
| Inspector | 500 | Stacked. Preview ~260pt tall, metadata ~280pt, filename and source pinned at top, raw data collapsed by default. |

Vertical budget at 640: toolbar 52, grid header 36, action row 44, leaving about 508pt for content. The action row stays as text buttons. Do not reduce Trash to an icon at any size.

Action row lives directly below the grid, left-aligned with the selection count: "3 selected" then Favorite, Export, Archive, Move to Trash. Export greys with a hover hint "Select one item to export" when the count is not one. Trash and Archive confirm when the count is above one, and the confirmation names the count.

## Challenges and guidance

**Density.** Reject side-by-side as the default. Make it a width rule as above. Thumbnail minimum 96pt so previews stay legible without the full-image view.

**Selection safety.** Opening a folder selects the first item outright, so there is never a previewed-but-unselected state. Click-through on a tile both selects and previews. Arrow keys move the single selection. In multi-select, the active item has a heavier border plus a checkmark and is always included. Trash label shows the count ("Move 3 to Trash"). Undo toast persists for the Trash action. Remote scope removes Archive and Trash from the row and shows one line: "Remote originals are read-only. Export saves a local copy."

**Remote first use.** Replace the sheet with an inline state in the rail's Remote section and a non-modal panel in the review area. One primary button, "Continue in RelayBar". One sentence of copy, no repetition. When RelayBar is not installed, show the sentence "RelayBar is not installed" with no button. On return to Frame, the panel updates itself and lists the granted paths. Retry appears only after a failed handoff, next to the error, and never clears the chosen location.

**Must change**
- Auto-select the first item; remove the "Not selected" state entirely.
- Active item is always part of the selection; counts appear in the action labels.
- Move Archive out of the filter segment into the rail as a child location of the root. Keep Favorites as a filter toggle.
- Keep a persistent path control in the toolbar when the rail collapses.
- Remote first-use becomes non-modal with a single action and no premature Retry.
- Inspector stacks below 640pt of width instead of forcing four columns.

**Optional**
- Replace "+ JSON" filename suffix with a small corner badge on the tile; keep the sidecar name in metadata only.
- Label the toolbar's purple button or fold it into the rail's Remote section.
- Middle-truncate paths and folder names everywhere.
- Collapse "Sidecar JSON" raw fields under a disclosure, with prompt and seed surfaced in the summary.

## Author correction

The purple top-left indicator is macOS screen-capture chrome, not a Frame UI control. That suggestion was not adopted. The next review explicitly clarified this.
