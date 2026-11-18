# Remote assets and preview cache

2026-10-22 correction: the remote Trash/write-confirmation design below was superseded by [direct remote Delete](2026-10-22-direct-remote-delete-and-shortcuts.md). Preview/cache acceptance remains separate.

Status: Implemented and installed; real-host acceptance pending
Created: 2026-10-22

## Objective

Remote folders use the same review, batch Trash, Archive and Restore actions as local folders. Browsing transfers small previews and metadata, not original media.

## Scope

- RelayBar retains SSH authority; a fixed, bounded helper runs over its existing connection. No daemon or automatic dependency installation. Python 3 is required; image previews require Pillow and video posters require ffmpeg/ffprobe.
- Contact sheet requests 512-pixel previews; enlarged previews request 2048-pixel previews. Metadata is extracted on the host. Full-resolution viewing, explicit video playback and exact-copy export may fetch originals.
- Persist previews and metadata in a bounded 512 MiB local disk cache. Host/path/rendition keys survive app restarts; validate with remote file identity, size and nanosecond timestamps before reuse. No silent original-download fallback.
- Archive and Trash move media plus uniquely paired JSON as one asset on the host. Use managed `Archive` and `.FrameTrash` folders, collision-safe records, original-path manifests and recoverable restore. Never recursively delete a user directory or overwrite a restore destination.
- Upgrade remote write consent separately from existing read consent. Surface actual host permissions and partial failures; do not label remote folders read-only.
- Keep directory scans passive and bounded. Frame never changes RelayBar history, including explicit subfolder opens. RelayBar owns its own recent-location writes.

## Acceptance

- [x] Cold grid/metadata requests never invoke original fetch; cached previews survive a new client and changed files invalidate cached data.
- [ ] Remote media/JSON archive, trash and restore work with common batch shortcuts, cancellation between assets, failures and destination conflicts.
- [ ] Fullscreen retains heart/delete; preview remains resizable; an explicit Original control opts into full pixels.
- [x] Automated helper/bridge/client tests cover path traversal, symlinks, stale files, missing dependencies, size limits and non-overwrite restoration.
- [x] Build/sign/install Frame and RelayBar in Applications; record verification and untested real-host limits. Do not publish.

## Decisions

Remote read-only was an initial implementation boundary, not a user requirement. This task replaces it. Remote Trash is recoverable on the remote host, not the Mac's Finder Trash. It is never automatically purged. Mutations do not download originals.

## Delivery record

Frame 0.6.0/9 and RelayBar 1.8.0/15 are installed. 78 Frame and 324 RelayBar tests passed; 22 existing RelayBar opt-in tests were skipped. Preview/cache and paired remote actions are verified with disposable fixtures; signed installed IPC/catalog and local-library restoration are verified. The remote native end-to-end acceptance boxes remain open because no private-host files were used for testing. See [evidence and limits](../system-specs/verification-2026-10-22-remote-assets.md) and [current contract](../system-specs/remote-assets.md).
