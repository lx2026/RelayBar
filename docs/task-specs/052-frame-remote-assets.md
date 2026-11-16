# Task 052 — Frame remote assets

2026-10-22 correction: the remote Trash/write-confirmation design below was superseded by [Task 053](archive/053-frame-direct-delete.md). Preview/cache real-host acceptance remains separate.

2026-11-08 reconciliation: the original requirements and delivery labels below are historical. [Task 054](archive/054-development-version-correction.md) restored marketing versions; [Task 055](archive/055-frame-batch-delete.md) expanded companion groups and batch Delete. Current behavior is defined in the [system spec](../system-specs/modules/frame-viewer.md). [Task 058](058-composable-app-architecture.md) owns the current composition refactor and overlapping verification. Its controlled live-SSH checks now cover Archive/Restore, batch Delete and interrupted operations, but signed native preview/cache and action acceptance remains open. Do not reintroduce a write prompt, remote Trash or persistent cache to satisfy this historical design.

Status: Implemented and installed; real-host acceptance pending
Created: 2026-10-22

## Outcome

Frame can preview and organize remote assets without transferring every original or duplicating SSH configuration.

## Delivery Boundary

Local update of both signed apps only. No publishing, credential changes, automatic host package installation or arbitrary remote-command bridge. Preserve existing work on `codex/frame-viewer-handoff` (base `5ebcfdd`, synchronized with origin/main before editing).

## Work

- Version the authenticated bridge for host-side previews/metadata and recoverable asset mutations. Keep original download explicit.
- Run a fixed Python helper over the existing SSH session with bounded input/output, safe paths, no symlink traversal and no-clobber paired moves. Image previews use Pillow; video posters use ffmpeg/ffprobe. Missing tools produce actionable errors, never an implicit full download.
- Add separate write consent, Archive/.FrameTrash manifests, Restore, stale-file rejection and per-asset failures. Listing/preview/mutation must not write recent history.
- Verify with disposable synthetic fixtures, automated broker/client tests and signed local builds. Update current specs and install evidence.

## Acceptance

- [x] Preview/metadata requests transfer only derived data and return stable fingerprints.
- [ ] Asset operations preserve paired JSON and reject unsafe/stale paths and destination collisions; remote recovery remains available after restart.
- [x] Existing read consent alone cannot authorize mutations.
- [x] Both apps pass relevant tests, signatures and installed launch checks; real-host verification limits are explicit.

## Delivery record

RelayBar 1.8.0/15 and Frame 0.6.0/9 are installed. Automated helper/broker/client tests and installed signature/catalog checks passed. Native real-host action acceptance remains open; no private-host source files were used. See [verification](../verification/052-frame-remote-assets.md). Frame never changes RelayBar history, including explicit subfolder opens; only RelayBar owns its recent-location writes.
