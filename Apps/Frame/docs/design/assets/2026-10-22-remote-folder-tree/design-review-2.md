# UI review

Date: 2026-10-22
This is reviewer feedback, not verified implementation status. Decisions and verification are recorded in the task spec.

Reviewed all five screenshots. The sheet and settings are ready. The workspace needs two corrections before shipping, plus three small copy fixes.

**Ship blockers**

- **Sidebar counts contradict the grid.** In the light tree, Photos is selected with a count of 2 while the header says 9 assets. The sidebar shows direct counts on remote and recursive counts on local, so the same column means different things per source, and neither tracks the checkbox. Rule to apply: a folder's sidebar count must equal what the grid shows when you click it. Make counts follow the Include subfolders state. On remote with the box checked, show a count only for folders already traversed and leave the rest blank.
- **Compact grid wastes half its width.** In the dark compact view the grid area is about 330pt wide and cells are about 160pt, yet it renders one centred column. Check the minimum cell width and spacing so two columns fit. Keeping the rail visible at 960pt is fine once this is fixed.

**Copy fixes**

- **Favorite 1** in the footer repeats the count from 1 selected and reads as a label with a stray number. Use Favorite. The star in the grid header is a filter and the star in the footer is an action, so the footer button needs its word anyway.
- **Retry in the Partial popover** implies failure. After a user-initiated Stop or a hit bound, nothing failed. Use Scan Again for all three causes, or Resume if the scan can actually continue.
- **Open sheet button placement** differs by section. Local puts Choose Folder… above its recents, Remote puts Browse in RelayBar… below. Put the action above the list in both, so the sheet reads the same top and bottom.

**Verify, not visible in screenshots**

- The up arrow in the Folders header has no label. Give it the tooltip Enclosing Folder and bind ⌘↑. Disable it at the share root on remote so it cannot expand to the host's filesystem root.
- Open… in the dark compact view renders dimmer than the other buttons and looks disabled. Confirm it is only dark-mode styling.
- Long recent paths in the Open sheet need middle truncation so the leaf folder stays readable. The test path fits, real ones will not.
- Scan progress, Stop, Partial, the empty remote line, and the disabled Browse state did not appear in any screenshot, so those remain unreviewed.

Everything else holds. Show remote folders as the toggle label, the sheet shrinking cleanly when remote is hidden, host bold with path grey, Read-only as a badge rather than a sentence, collapsed Embedded metadata with a field count, and the empty folder shown in the tree with no count all match the earlier review.
