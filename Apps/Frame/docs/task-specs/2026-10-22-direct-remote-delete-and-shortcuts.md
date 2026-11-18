# Direct remote Delete and viewer shortcuts

Status: Completed
Created: 2026-10-22

2026-10-22 correction: marketing labels restored to Frame 0.1.0 and RelayBar 1.6.0; builds 10 and 16 and all functionality retained. Both rebuilt and reinstalled. See the version-label correction in the linked verification record.

## Outcome

Remote Delete means permanent removal, immediately, without confirmation. The Delete key does the same thing. Full-size arrow buttons and Left/Right keys show the previous/next file without leaving the viewer. Archive remains separate.

## Delivery boundary

Frame and RelayBar, including signed local Applications updates. Remove remote Trash, its recovery/undo path, the extra write-permission prompt, and redundant collection plumbing. Preserve local macOS Trash behavior, Archive/Restore, preview caching, and RelayBar history isolation. Do not delete existing host data during testing or publish a release.

## Acceptance

- [x] Remote Delete unlinks only the selected media and paired JSON, including assets in Archive. No Trash creation, delayed deletion, confirmation or Undo.
- [x] Batch and singular viewer actions use the same delete path; failures report the files that failed.
- [x] Plain Delete/forward Delete and Command-Delete work in Browse and Inspect. Editing text or an open sheet does not delete media.
- [x] Viewer arrows traverse the visible folder/filter, not just the selected batch; selection remains in full-size view.
- [x] Both test suites pass after cleanup; both signed apps are installed and native navigation is checked.

[Verification and installed versions](../system-specs/verification-2026-10-22-direct-delete.md).

## Verification boundary

Permanent deletion is tested on disposable fixtures only. Existing remote files, including any previously created `.FrameTrash`, are not migrated, restored or purged by this update. No private-host performance or live deletion claim is made.
