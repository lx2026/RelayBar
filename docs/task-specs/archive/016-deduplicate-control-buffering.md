# Task 016 — Deduplicate Control Output Buffering

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`TunnelStore.appendControlOutput` carries two copies of the same append-and-trim logic, differing only in which dictionary they touch, and the two pipe `readabilityHandler` closures in `runControlForward` are identical but for a Bool. One statement of each keeps the trim bound in a single place.

## Work

- Express the append-and-trim once over the selected buffer.
- Build the two readability handlers from one shared closure factory.
- Preserve the existing `controlOutputLimit` trimming behavior on both streams.

## Acceptance

- Output and error buffers still trim to the same limit as before.
- Control-forward success and failure paths return the same output and error text.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
