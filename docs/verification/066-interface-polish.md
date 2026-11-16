# Task 066 — interface polish

Date: 2026-11-16. Implemented and committed locally; the owner has not yet reviewed the result. No push, version change or installation occurred.

## What changed

RelayBar:

- Popover icon buttons share one 28-point circular shape, including the row menu. Only the action most likely wanted next is filled with the accent colour: Start on a stopped or failed tunnel, Open in Browser on a running one, none while retrying.
- Footer and secondary text use a readable colour in both appearances.
- Section labels, card shape, header and toolbar heights and the neutral fill come from one set of shared values. Settings rows use one row layout.
- Content keeps its leading inset when an always-visible scroller narrows the popover.

Frame:

- Selected tiles use an accent ring, matching sidebar selection; the focused tile's caption is filled.
- Move to Trash sits beside the selection count, apart from Favorite, Export and Archive.
- Back and forward moved into the toolbar, removing the row that held only those two controls. In document view the file filter is an icon button.
- The Subfolders checkbox shares the grid header row. Section labels, icon buttons, insets and bar heights come from one set of shared values.

Thirteen source files changed: 589 lines added and 536 removed. Behaviour, strings, shortcuts and accessibility labels were not meant to change; that was not checked in a running app.

## Captures

Both apps were captured before and after with the same data in light and dark appearance: RelayBar through its test capture harness, which gained cases for row states and composed Settings; Frame through its separate verification build with the synthetic library. Four reviewed pairs are kept here; all 24 are in the git-ignored `.build/task-066-design/`.

- [RelayBar row states](assets/066-interface-polish/relaybar-row-states.png)
- [RelayBar remote selection](assets/066-interface-polish/relaybar-remote-selection.png)
- [Frame grid selection](assets/066-interface-polish/frame-grid-selection.png)
- [Frame document](assets/066-interface-polish/frame-document.png)

## For the owner

- With every tunnel stopped, each row now carries a filled accent Start button; before, the filled button meant a live tunnel. A tinted rather than filled emphasis would be calmer at rest.
- Frame's file filter is less discoverable as an icon in document view.
- Popover rows are about three points taller, so slightly less of a fourth row shows at the default height.
- The Plugins window was left alone. Its feature map names internal features; hiding it behind a control would suit people who only want the switches.

The work was interrupted before its authors reported, so this record comes from the captures and the diff. Twenty of the 24 pairs were not reviewed individually.

## Checks

9 script tests; 94 shared tests with 3 skipped; 433 RelayBar tests with 31 skipped; 190 Frame tests with 2 skipped; no failures, including the popover layout tests. The Frame product builds with warnings as errors, the unsigned Release build of the RelayBar project succeeds, and `git diff --check` is clean. Log: `.build/task-066-gate.log`.
