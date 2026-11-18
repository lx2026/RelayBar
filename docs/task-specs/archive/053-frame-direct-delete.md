# 053 — Frame direct remote Delete

Status: Complete
Created: 2026-10-22

2026-10-22 correction: [Task 054](054-development-version-correction.md) restores RelayBar 1.6.0 and Frame 0.1.0 marketing labels while retaining builds 16/10 and all functionality. Original delivery labels below are historical.

## Outcome

Frame Delete immediately unlinks remote media and paired JSON with no confirmation, Trash, delayed action or Undo. Archive/Restore remains separate.

## Delivery Boundary

Replace the Frame bridge's remote-trash workflow, not RelayBar's own file-browser UX. Remove the separate write prompt and unused collection abstractions. Keep linked-app identity checks, exact selected-file validation and history isolation. Build/sign/install both apps locally; no publication or private-host test mutations.

## Work

- Remove trash/recovery protocol routes and use direct unlink for selected regular files.
- Keep archived-asset deletion scoped to the selected pair and its now-empty record.
- Record partial failures without creating recovery files.
- Verify helper and bridge regressions, signatures, installed versions and companion launch.

## Acceptance

- [x] Fixture media/JSON permanently disappear; unselected and stale files remain untouched.
- [x] Linked Frame can delete without another permission dialog; history remains unchanged.
- [x] Archive/Restore, preview/cache and protocol compatibility regressions pass.
- [x] Final cleaned build and Applications installation verified.

[Verification](../../verification/053-frame-direct-delete.md): 326 RelayBar tests passed (22 opt-in skips), 82 Frame tests passed, native keyboard/navigation checks and installed bridge connectivity verified. RelayBar 1.8.1/16 and Frame 0.6.1/10 installed.

Live private-host deletion remains untested; no remote data is cleaned up automatically.
