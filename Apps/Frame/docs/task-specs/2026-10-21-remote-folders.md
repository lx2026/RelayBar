# Remote folders

Status: Implemented and installed in 0.3.0 — live-host acceptance pending
Created: 2026-10-21

## Objective

Browse a user-selected remote media folder in Frame's existing Contact Sheet with attached preview and metadata.

## Scope

Use the [remote/assets design](../design/2026-10-21-remote-archive-assets.md). Recommended first version: saved SSH host plus absolute path, folder-by-folder SFTP listing, on-demand preview cache, local favorites, and exact export to a selected local destination. No mount driver, sync, remote indexing, uploads, or new tunnel controls.

## Acceptance

- [x] User confirmed in-app SSH/SFTP browsing with saved hosts and paths, not an OS mount.
- [x] Signed sandbox-to-RelayBar authentication and strict known-host SFTP proved with disposable fixtures; installed peer handshake passed.
- [x] Connection-derived root UUID plus absolute media path retains favorites across folder openings; cache URLs remain separate.
- [x] Connection is explicit; selecting a saved host does not connect. Successful listings update RelayBar's single catalog; errors preserve selected source/path.
- [x] Bounded listings/transfers, selected-preview priority, cancellation, retry and stale-result guards implemented. Remote video requires explicit open and shows progress.
- [x] Names, JSON, paths, and server output are untrusted; no bridge shell operation, credential logs or disabled host-key checks.
- [ ] Tests cover offline/auth/host-key failures, hostile paths, cancellation, stale cache, size limits, and reconnect without mutation replay.
- [ ] Real-host acceptance uses a user-selected disposable fixture folder; do not browse private hosts merely to test.
- [x] Current-state docs and both Applications bundles updated; remote capabilities are separate from local mutation.

## Exclusions

No remote deletion, Archive/Restore, uploads, Finder mount, or separate SSH credentials/history. The later user request explicitly expanded scope to modifying RelayBar for its connection broker and one-click handoff.

[Verification and remaining limits](../system-specs/verification-2026-10-22.md). [Companion handoff spec](2026-10-22-relaybar-viewer-handoff.md).
