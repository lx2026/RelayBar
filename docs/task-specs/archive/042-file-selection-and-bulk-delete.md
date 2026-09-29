# Task 042 — File Selection Mode and Bulk Delete

Status: Complete

Created: 2026-08-30

Completed: 2026-08-30

Follows: Task 041

## Outcome

The Remote Files browser has a reusable, action-neutral selection mode entered
through a top-level **Select** button. A person can select multiple regular
files with ordinary clicks and apply a bulk action. Task 042 delivers permanent
bulk Delete as the first action without making the entry point deletion-specific.

## Delivery Boundary

### Included

- A top-level **Select** button in the folder browser.
- An explicit selection mode with file-row checkmarks, selected count, Cancel,
  and a dedicated action area.
- Ordinary-click selection of multiple regular files without Command-click or
  Shift-click. Folders remain visible but are not selectable.
- Immediate, no-confirmation bulk Delete using Task 041's exact-path safety and
  truthful outcome rules.
- Keyboard, focus, accessibility, narrow-window, and large-text behavior.
- A selection model and action surface that can accept additional file actions
  later without changing the top-level **Select** entry point.

### Excluded

- A persistent top-level Delete button, native modifier-key multi-selection,
  drag-and-drop deletion, or any confirmation popup.
- Selecting or deleting folders, symbolic links, recursive targets, wildcard
  targets, preview siblings, or items across folders.
- Delivering additional bulk actions such as Download in this task. Those need
  their own destination, conflict, progress, and cancellation contract, but
  must be able to reuse this selection mode.
- Commit, push, release, notarization, publication, or deployment.

## Interface

- In normal browser state, **Select** sits with Refresh and Upload. Existing
  single-row actions and double-click behavior remain unchanged.
- Choosing **Select** keeps the current folder visible, replaces row actions
  with explicit circular selectors on regular-file rows, clears the temporary
  bulk selection, and shows **Cancel**, **0 Selected**, and a disabled Delete
  action. Folders have no selector and cannot open while the mode is active.
- A normal click anywhere on an eligible file row toggles its checkmark. The
  selected count updates immediately. Delete names the count and is enabled
  only when at least one current regular file is selected.
- **Cancel** exits the mode without mutating remote state and restores the
  prior ordinary row selection. Escape performs the same action.
- Choosing Delete submits immediately with no second step. Fully acknowledged
  deletion exits selection mode and selects the next surviving row at the first
  deleted row's former index. A partial or non-acknowledged result keeps the
  mode open, removes acknowledged targets, preserves failed and unattempted
  selections, and reports the result inline rather than in a popup.

## Work

- Add a browser-local selection-mode state that is separate from ordinary
  single-row selection and resets on folder, host, window, or session changes.
- Build explicit file-only selectors and action-neutral selection APIs. Block
  navigation, preview, refresh, upload, download, and row mutation while the
  mode or submitted batch owns the folder.
- Process the stable folder-ordered selection sequentially. Revalidate each
  file immediately before its one quoted SFTP `rm`, stop at the first
  non-acknowledged result, and never retry automatically.
- Preserve Task 041's generation ownership, cache reconciliation, same-name
  recreation handling, close/quit retirement, and truthful rejected, stale,
  and outcome-unknown semantics.
- Add model, service, keyboard, accessibility, and visual coverage for entry,
  toggling, Cancel, file-only eligibility, full success, partial failure,
  selection repair, mode reset, and absence of confirmation or drag UI.

## Acceptance

- The browser exposes **Select**, not a top-level Delete button. Entering it
  presents explicit file-only selection controls and a reusable action area.
- Multiple files can be selected with ordinary clicks; folders never receive a
  selector or destructive action, and Cancel/Escape performs no remote change.
- Delete is disabled at zero selected files and otherwise begins immediately
  without confirmation, drag-and-drop, or modifier-key selection.
- Batch removal is stable and sequential with a fresh Task 041 preflight per
  file. The first failure stops submission and preserves failed or unattempted
  selection with truthful inline status.
- Full success exits the mode and repairs ordinary selection at the first
  deleted index. Navigation or session replacement cannot retain stale bulk
  selection or accept late callbacks.
- The approved wireframe, relevant automated and visual checks, system-spec
  updates, and `git diff --check` are recorded before completion.
