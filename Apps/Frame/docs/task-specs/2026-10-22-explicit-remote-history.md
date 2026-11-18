# Remember only explicitly opened remote folders

Status: Completed
Created: 2026-10-22

## Outcome

Frame scans, folder expansion, refresh and thumbnail capability renewal must not add or promote RelayBar recents. Only successfully displayed, explicitly chosen folders do—including cached and empty folders. Preserve existing history.

## Decision

Bridge v2 makes `list` passive and adds `rememberOpen`, sent after successful explicit navigation or handoff. This tiny local request is independent of directory-cache/listing expiry; no extra SFTP listing is needed for a cached open. The broker accepts only an authorized, authenticated viewer, known host and validated absolute path. It does not verify the path again over SSH. Old/new protocol pairs fail with an update message before listing, preventing a silent return to v1 history pollution.

## Acceptance

- [x] Expansion, recursive traversal, refresh and renewal never write recents.
- [x] Explicit navigation remembers successful cached/empty folders; failed, hidden or superseded opens do not.
- [x] Shared history preserves identity, deduplicates and promotes explicit reopens; existing history is not cleared.
- [x] Both test suites and signed builds pass; installed Frame 0.5.1/7 and RelayBar 1.7.1/13 with recoverable prior apps.

No public release, notarization, feed change, UI redesign or remote file mutation is included.

## Completion record

Delivered 2026-10-22. Frame: 73 tests passed. RelayBar: 334 tests executed, 22 opt-in skips, no failures. Native installed Frame restored its library and preferences and read the companion's shared catalog. No live-host scan was performed. [Verification and rollback paths](../system-specs/verification-2026-10-22-explicit-history.md).
