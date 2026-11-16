# Archive assets

Status: Implemented and installed in 0.3.0 — extended failure acceptance remains
Created: 2026-10-21

## Objective

Set aside selected assets without losing their media, JSON, favorites, or a clear way back.

## Proposed scope

Confirmed behavior is a reversible move, not ZIP: an `Archive` subfolder within the source root, excluded from normal All/Favorites browsing, with an Archive scope and Restore action. Each asset occupies a UUID directory with a durable original-relative-path record. Keep source metadata untouched and include every paired file. Restore refuses occupied original paths.

See the [shared design](../design/2026-10-21-remote-archive-assets.md). The user confirmed this choice in chat on 2026-10-21.

## Acceptance

- [x] Confirm the desired Archive behavior and destination.
- [x] Batch selection and counts use logical assets, with member details available before mutation.
- [x] Preflight all members; preserve hierarchy and favorites. Refuse existing paths, path traversal, symlinks and cross-volume moves.
- [x] Failed member moves roll back safely or report recovery paths; injected disk-full and rollback-collision tests pass.
- [x] Durable records reload in a fresh scan and Restore refuses occupied original paths; native Archive/Restore pair passed.
- [x] Existing folders named Archive are not silently adopted or hidden.
- [ ] Test empty/batch operations, duplicate stems, cancellation, disk-full, permission denial, rollback failure, and moved roots.
- [x] Remote Archive is unavailable at both UI and service boundaries.

[Verification and remaining physical-failure limitations](../system-specs/verification-2026-10-22.md).

## Exclusions

No compression unless selected by the user, no background archiving, no permanent deletion, and no automatic moves of user media during development.
