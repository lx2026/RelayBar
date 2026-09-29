# Task 041 — Direct Remote File Deletion

Status: Complete

Created: 2026-08-29

Accepted: 2026-08-30

Follows: Task 037

## Outcome

Remote Files can permanently delete one selected remote regular file from its
browser row or preview without confirmation. An acknowledged image deletion
keeps preview open and advances to the next image, falling back to the nearest
earlier image and returning to the browser only when no image remains.

## Delivery Boundary

### Included

- A visible selected-row trash action, final destructive context-menu action,
  preview-toolbar action, focused Command-Delete shortcut, and named
  accessibility action.
- Immediate deletion with no alert, sheet, popover, drag target, undo, or other
  confirmation step.
- Exact-path fingerprint revalidation and one quoted SFTP `rm` through the
  active app-owned SSH master.
- Truthful acknowledged, rejected, stale, and outcome-unknown results; in-place
  refresh; cache and selection repair; image-preview advancement; and mutation
  lifecycle isolation.
- Automated, offscreen visual, accessibility, security, and lifecycle evidence
  plus updated system documentation.

### Excluded

- A top-level **Select** control, multi-selection, or batch actions. These need
  a reusable selection-mode design and are tracked by Task 042.
- Directory, symbolic-link, recursive, wildcard, or drag-and-drop deletion.
- Remote Trash, quarantine, undo, recovery, retention, secure erase,
  confirmation UI, or automatic retry.
- Commit, push, release, notarization, publication, or deployment.

## Work

### 1. Provide direct single-file actions

- Show the selected regular file's trash action beside Download, add Delete as
  the final destructive context-menu command, and add Delete beside Download in
  preview. No action uses an ellipsis or presents confirmation UI.
- Limit Command-Delete to browser or preview detail focus. Expose the same
  named action to accessibility APIs.
- Disable deletion unless the target is a current regular file in the active
  normalized folder and no listing, preview, upload, download, refresh, or
  deletion operation is active.
- Replace controls with an in-place **Deleting <filename>…** strip after
  submission. Do not offer Cancel because cancellation cannot guarantee that
  the server left the file unchanged.

### 2. Revalidate and remove the exact entry

- Capture the active master token and the displayed path, kind, size, and
  modification text. Immediately relist the exact path through that master and
  refuse a changed, missing, indirect, non-regular, or stale target before
  submission.
- Submit one shell-free, quoted `SFTPCommandBuilder.removeCommand` for the exact
  path. Preserve existing path, output, diagnostics, SSH argument, batch input,
  pipe, ownership, and cancellation bounds.
- Call the operation deleted only after acknowledged SFTP success. Distinguish
  server rejection from a command that was never submitted and an outcome that
  became unknown after submission. Never retry automatically.

### 3. Reconcile the browser and preview

- Refresh in place after an acknowledged deletion and show any same-name entry
  recreated by another client. In the browser, select the row now at the
  removed row's index, then the preceding row when the removed file was last.
- In image preview, open the next supported image at the deleted image's index,
  fall back to the nearest earlier image, and return to the browser only when no
  image remains. Non-acknowledged outcomes do not advance.
- Announce the deletion and next-image result through macOS accessibility
  without adding a success popup.
- Keep deletion session-only, generation-guarded, and owned until its child is
  reaped during close or quit.

## Acceptance

- Every visible, keyboard, and accessibility path starts exact-path
  revalidation immediately and presents no confirmation or drag-and-drop UI.
- Unsupported, stale, indirect, or operation-blocked targets submit no `rm`;
  one valid regular file uses one quoted, shell-free SFTP removal.
- Only acknowledged success is called deleted; rejected and unknown outcomes
  remain truthful, refresh current state, and never retry automatically.
- Browser selection repair and image-preview next/previous/no-image behavior
  match the defined rules without hiding concurrent same-name recreation.
- Focused automated tests, the full Swift suite, visual captures, build checks,
  system specifications, and `git diff --check` pass, with evidence recorded in
  `docs/verification/041-remote-file-deletion.md`.

## Completion

The delivered single-file behavior, automated suite, offscreen visual evidence,
system specifications, and installed local review build were accepted on
2026-08-30. An isolated writable live-SSH exercise remains documented as
release-hardening evidence rather than a completion blocker.
