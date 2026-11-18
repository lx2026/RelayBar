# Frame document workspace

Status: Complete — 2026-11-07

## Outcome

Frame previews Markdown and interactive HTML from RelayBar folders, alongside existing images and video.

## Delivery Boundary

Bridge protocol 6 adds one bounded metadata check for up to 128 document resources. Existing authorized file transfers deliver only requested documents and dependencies. Markdown and HTML are independent primary files; Archive/Delete never include their referenced assets. Frame navigation and checks never update RelayBar history. Rendering happens on the Mac; no remote web server is installed.

Release version stays 1.6.0. The user authorized rebuilding and updating both apps in Applications, with no publication.

## Work

- [x] Extend the shared protocol and fixed helper for batched document checks.
- [x] Keep Markdown/HTML independent of image companion grouping.
- [x] Test document changes, containment, Archive/Restore/Delete and history isolation.
- [x] Run complete regression checks and update current-state docs.
- [x] Build, sign and install RelayBar 1.6.0/18 with a build-number increment only. Frame 0.1.0/14 is also installed.

## Acceptance

- Frame renders the same HTML/Markdown fixtures through local and remote resource transports.
- Resource checks reject traversal and symlinks and remain bounded; opening a document does not fetch unrelated files.
- Existing media/group deletion, Archive and history tests pass.
- Installed release version is unchanged; strict code signing verifies.

Evidence: 353 tests executed, 329 passed, 24 optional skips, zero failures; matching universal executable/dSYM UUIDs, strict signatures, mirrored wire files and whitespace checks pass. Previous Applications bundle is preserved in Frame’s `.build/backups/2026-11-07-documents/`. Both installed apps were relaunched successfully. Native Frame rendered existing Markdown and HTML from a saved RelayBar folder without changing remote files. Local native screenshots and interaction checks are recorded in Frame’s verification document. Real-host throughput and injected SSH failures are not claimed.

Frame’s main spec is `docs/task-specs/2026-11-05-folder-workspace-and-document-previews.md` in the previous Frame working folder (now `Apps/Frame/`); its verification record is `docs/system-specs/verification-2026-11-07-documents.md`.
