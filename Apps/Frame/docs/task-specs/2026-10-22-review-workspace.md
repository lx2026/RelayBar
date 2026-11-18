# Clearer review workspace

Status: Completed — implementation delivered and Frame 0.4.0 (build 5) installed; extended acceptance limits recorded below
Created: 2026-10-22

## Objective

Make folder selection, image review and culling understandable from one grid-led screen while retaining metadata beside the active image.

## Design

The [design and flow](../design/2026-10-22-review-workspace.md) are authoritative, including native-prototype screenshots, alternatives, design review evidence and tradeoffs. The user accepted the grid-led layout with the larger, resizable preview.

## Scope

One stable grid-led workspace; visible recent locations and current folder children; explicit active selection; resizable grid/preview/metadata; local Archive destination; counted batch actions; clearer RelayBar first-use and recovery states. Existing functionality and data formats remain intact.

## Acceptance

- [x] User approves the design and default layout, keeping the larger resizable preview.
- [x] Click selects and previews; active item is always in selection. Empty selection has no actionable stale preview. Scope changes and batch operations cannot target hidden or stale IDs.
- [ ] Command/Shift/Command-Shift, Select All/Clear, arrows, Return, Escape, Command-Delete, and Undo behave predictably without intercepting editable metadata, menus or player controls.
- [x] Root switch, nested subtree selection and authorized remote recent-path opening need no long dropdown. Paths stay understandable when the rail is collapsed. Remote catalog recovery is unit-tested; live-host acceptance is separate.
- [x] Thumbnail sizes 100–360 pt, grid/review split and image/metadata split resize and persist. Large previews remain appropriately downsampled; no full-resolution decode for every tile.
- [x] At 1280×800 and 960×640, light/dark, long names, portrait/wide images and mixed video posters, controls do not clip and image plus useful metadata stay visible together.
- [x] Batch Archive/Trash show asset/member counts, preserve pairing and use clear confirmation/Undo. Restore refuses collisions. Export is single-asset and replaces destination metadata as already specified.
- [x] Enlarge/full-screen remain available. Full screen has visible heart, local Trash and Undo; these act on the current asset even when a larger batch was selected.
- [ ] Remote setup has one inline primary action; approved handoff returns automatically. Offline, denied consent, revoked consent, missing/outdated RelayBar and missing Frame retain clear recovery without invented download links.
- [ ] Real 5,000-asset local and simulated high-latency remote workloads validate cancellation, scroll stability, selection stability and bounded memory; no performance claims from static mocks.
- [ ] VoiceOver announces active vs selected, resize controls and action targets. Keyboard-only navigation passes.
- [x] Existing and revised regression tests pass (57 total), including new selection/scope, batch favorite, JSON provenance and remote-catalog recovery tests. Current-state docs updated after installation.

## Delivery and verification limits

Frame was rebuilt, Developer-ID signed, installed in Applications and relaunched. The previous 0.3.0 app is preserved in project backups; favorites, recent roots and thumbnail preferences survive. RelayBar was not updated or restarted. [Verification, screenshots, hashes and rollback paths](../system-specs/verification-2026-10-22-review-workspace.md).

Unchecked items above are extended acceptance, not claims of passed tests. Keyboard range/Select All/Clear/Return/Escape/Trash/Undo and native resizing were exercised on disposable fixtures; the entire editable-control/VoiceOver matrix was not. The 5,000-file scanner/query benchmark passed, but a 5,000-tile native stress session and high-latency remote UI benchmark were not run. The earlier live-host consent/handoff and remote-failure matrix remain pending; no private host was opened. These limits do not change the delivered read-only remote security model.

## Exclusions

No public release, RelayBar update, access to private remote hosts for testing, operations on the user's real media, new library features, or two competing layout modes. Install only Frame after testing against disposable fixtures; preserve a recoverable copy of the currently installed app and its preferences.
