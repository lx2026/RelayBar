# 2026-10-21: Simplified folder selection

Task status: Completed — 2026-10-21; manual recovery matrix limits recorded below\
Design status: Accepted — user approved implementation; see the Contact Sheet amendment for later selection changes

## Outcome

Choose, switch, and revisit a folder from one visible control, with more room for the selected media and metadata.

[Reviewed design and rejected rail alternative](../design/2026-10-21-frame-redesign.md) · [Interactive mock](../design/assets/2026-10-21-frame-redesign/frame-redesign.html)

## Layout and flow

- Remove the permanent Inspect sidebar and its duplicated library/filter rows. The later Contact Sheet amendment adds an optional folder outline in Browse only.
- On first launch, show Choose Folder, folder drop affordance, and recent folders once. Do not repeat them in an empty toolbar.
- After opening, the toolbar folder-name button offers Choose Folder, up to eight recent roots, and Refresh. Show a secondary location so equal folder names are distinguishable.
- Use the Contact Sheet folder outline for subfolders, replacing the originally proposed dropdown. Include All files and nested folders; tooltips show full relative paths. The selected scope includes descendants.
- Show All/Favorites once. It filters the current subtree and never silently changes the root.
- Keep the filmstrip, Contact Sheet, Focus, and attached metadata panel. The native minimum window remains 960 × 640; small-screen stacking in the mock is only for review.

## Root and selection behavior

Use the native folder panel (`⌘O`) or a folder drop to grant access. Normal root changes reset scope/filter, stop playback, and preview the first supported item with no batch targets selected. Favorite state remains attached to its existing root ID and relative path.

Build recents from existing bookmark records, deduplicate resolved roots, and display the eight most recently opened. The display limit must not discard catalog/favorite records for older roots. Switching roots while a scan is in flight must cancel or ignore stale results.

When a bookmark cannot resolve or access expires, show the retained folder name with Unavailable and a Locate Folder action. Reauthorizing that record retains its root ID and favorites. Removing its recent shortcut must not delete files or favorite data. Reopen the last available root on normal relaunch; an unavailable last root must offer recovery rather than silently changing libraries.

Manual Refresh (`⌘R`) remains. Live filesystem watching is deferred.

## Empty, error, and undo behavior

- Empty root: “No supported media here,” list formats, offer Choose another folder.
- Empty Favorites: “No favorites here,” offer Show all files within the same folder scope.
- Missing root: show Locate Folder in the workspace and Unavailable in the chooser/recents; disable source-dependent commands.
- Missing selected file: clear stale display, report it, and reconcile selection on Refresh.
- Trash: advance selection and show a seven-second Undo notice near the viewer footer. Keep a bounded session undo stack accessible through Edit → Undo/`⌘Z` after the notice disappears; never overwrite an occupied restoration path.
- Escape closes one active layer per press. Opening a menu or sheet suspends global media shortcuts. Restore meaningful keyboard focus after dismissal.

## Acceptance and verification

- [x] Open, switch, and reopen recents verified natively without import or duplicate chooser UI. Folder-drop handling is implemented; native drag/drop remains a manual follow-up.
- [x] Nested scope and Favorites compose correctly, including root-level media plus one child folder.
- [x] Stale scans/metadata cannot commit over a newer root in regression tests; playback clears on root/scope changes.
- [x] Native bookmark relaunch and automated favorite/relocation identity tests pass.
- [x] Unavailable bookmark, missing selection, empty root, and empty Favorites logic tested. Physical-volume/expired-access UI checks remain manual.
- [x] Native keyboard ownership and layered Escape verified; session Trash/Undo and command availability covered by tests.
- [x] Browse/favorite/filter operations create no sidecars or source metadata writes.
- [x] Native primary-workspace screenshots recorded in both appearances; recents and nested scope inspected. Recovery screenshot matrix was reduced to automated state checks for this delivery.

## Completion record

Delivered in Frame 0.2.0 (build 2), installed in Applications. One root chooser replaces the old permanent Inspect sidebar. Recents are capped/deduplicated without deleting catalog records; Locate retains root UUID/favorites; stale scans are guarded. The user’s later request supersedes the dropdown with the [Contact Sheet folder outline](2026-10-21-contact-sheet-selection.md).

Verification: 30 tests passed, native root switching/relaunch and recents menu checked, and the user’s previously open root restored after installation. [Delivery evidence](../system-specs/verification-2026-10-21.md) records screenshots, artifacts, and backup.

Deviation/follow-up: native drag/drop, physical drive disconnection/reauthorization, complete VoiceOver traversal, and the full Light/Dark recovery screenshot matrix were not exercised. Their absence is not presented as a passed check. No filesystem watcher or catalog migration was added.
