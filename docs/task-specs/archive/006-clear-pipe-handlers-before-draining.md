# Task 006 — Clear Control Pipe Handlers Before Draining

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

Remove the concurrent-reader race in `TunnelStore.finishControlOperation`. It drains both control pipes with `readDataToEndOfFile()` while their `readabilityHandler`s are still installed, then clears the handlers afterwards. Two readers consume one descriptor, and a handler block dispatched late can recreate `controlOutputBuffers[id]` after cleanup, so the next rule's error text can carry the previous rule's stderr.

## Work

- Clear both `readabilityHandler`s before draining the pipes.
- Make the late-append path inert once an operation has finished, so a block that lands after cleanup cannot resurrect a buffer.
- Keep the drain bounded by the existing `controlOutputLimit` behavior.

## Acceptance

- Handlers are nil before any synchronous read of the same descriptor.
- An append delivered after `finishControlOperation` leaves no buffer behind for that tunnel.
- Control-forward output and error text still reach `ControlResult` for a normal, a failing, and a timed-out operation.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
