# Task 011 — Bound Directory Download Progress Polling

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

Recursive-download progress calls `localSize`, which enumerates the whole partial tree and re-stats every file already written, once per second for the entire transfer. The cost grows with the download and competes with `sftp` for the same I/O, so the largest transfers pay the most.

## Work

- Back the polling interval off as the enumerated tree grows, keeping the current responsiveness for small transfers.
- Keep the maximum-bytes enforcement and the final progress report exact.
- Leave single-file polling unchanged; it is one `stat`.

## Acceptance

- A directory transfer's polling interval grows with tree size instead of staying fixed at one second.
- Progress still reaches the true total on completion.
- The preview and download size limits still abort transfers that exceed them.
- Cancellation still stops polling promptly.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
