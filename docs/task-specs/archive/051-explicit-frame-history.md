# Task 051 — Explicit Frame folder history

Status: Complete
Created: 2026-10-22

## Outcome

Frame's passive directory reads must never fill or reorder RelayBar's recent folders. Remember only explicit, successful folder opens and keep existing history.

## Delivery Boundary

Bridge v2, focused regression tests, system specifications and local signed installation of RelayBar 1.7.1/13 and Frame 0.5.1/7. Preserve all existing uncommitted Task 050 changes. No commit, push, publication, notarization, feed change or user-host access.

## Work

- Make `list` passive; add authenticated, consent-gated `rememberOpen` for a known source and validated absolute path.
- Frame calls it after successful explicit opens, including cache hits, never on scan, expansion, refresh or renewal.
- Require protocol v2 on both sides so mixed versions cannot silently pollute history.
- Rebuild and install both apps with backups; a brief tunnel interruption is authorized.

## Acceptance

- [x] Many passive listings preserve recent paths, order, identities and notification count.
- [x] Explicit opens promote/deduplicate shared history without another SFTP operation.
- [x] Version, consent, unknown-host and malformed-path guards reject history changes.
- [x] Relevant tests, universal signed build, installed metadata/signatures and launch pass.
- [x] Current system specs and verification evidence updated; `git diff --check` clean.

## Completion

Delivered 2026-10-22. RelayBar: 334 tests, 22 opt-in skips, no failures. Frame: 73 tests passed. Both apps installed, signed and running; installed Frame read the companion catalog. Existing history retained. No live-host scan or public release. See [verification](../../verification/051-explicit-frame-history.md).
