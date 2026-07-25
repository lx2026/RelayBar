# Task 015 — Table-Driven sftp Error Messages

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`SFTPRemoteFileService.friendlyMessage` maps stderr text to user-facing wording through eight sequential `if` statements. The mapping is data, and expressing it as data makes the set readable at a glance and each new case a single line.

## Work

- Replace the branch chain with an ordered table of matched text and replacement message, preserving the current order so overlapping matches still resolve identically.
- Keep the existing control-character stripping, 512-character bound, and `sftp>` line filtering ahead of the match.
- Correct the one message that uses a straight apostrophe so all user-facing strings use the typographic form.

## Acceptance

- Every input that produced a given message before produces the same message, apostrophe correction aside.
- Unmatched output still falls back to the bounded detail text, and empty output to the generic failure message.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
