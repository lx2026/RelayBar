# Task 046 — Remote Delete Undo Window

Status: Complete

Created: 2026-09-28

Completed: 2026-09-28

Evidence: [Verification](../../verification/046-048-remote-files-and-editor-usability.md)

## Outcome

Prevent a mistaken single or bulk delete from immediately destroying a remote
file while retaining a single-action deletion flow.

## Delivery Boundary

Forward the existing regular-file deletion paths only after a five-second
Undo window. This supersedes Tasks 041/042's immediate-deletion behavior;
there is no server trash, recovery after submission, or automatic retry.

## Work

- Show an inline pending-deletion strip with Undo before any server mutation.
- Cancel an unsubmitted deletion on Undo, close, or shutdown; preserve the
  selection/preview and existing post-submission reconciliation semantics.
- Remove row trash beside Download; retain context-menu, keyboard, preview,
  and bulk entry points, all routed through the same delay.
- Give bulk Delete explicit red destructive styling and accurate help text.

## Acceptance

- Single and bulk deletes submit nothing before the delay; Undo and close
  during that delay submit nothing even after the original deadline.
- After the delay, revalidation, sequential submission, partial failure, and
  unknown-outcome handling remain correct without automatic retries.
- Tests, light/dark visual evidence, system specs, and diff checks pass.
