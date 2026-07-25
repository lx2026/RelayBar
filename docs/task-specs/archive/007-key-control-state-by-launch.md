# Task 007 — Key SSH Control State by Launch

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

Stop a restart from failing on stale control state. `stop(id:)` terminates the control process but leaves `controlProcesses[id]` populated until the termination handler reaches the main queue. A `start()` inside that window makes the first `runControlForward` return "Another SSH control operation is still running," which fails startup and drops the profile into retry backoff with a misleading message.

## Delivery Boundary

### Included

- Per-launch identity for control-process state so a new launch is never blocked by a previous launch's teardown.
- Preserved continuation safety: every `runControlForward` continuation must still resume exactly once, including on stop, cancel, timeout, and launch failure.

### Excluded

- Concurrent control operations for one profile. Rules stay sequential.

## Work

- Give each `launchTunnel` call a generation value and carry it through control-process, pipe, buffer, timeout, and continuation state, following the generation pattern already used in `RemoteFilesModel`.
- Treat state from a superseded generation as dead: ignore its callbacks and never let it reject a current operation.
- Keep the existing single-operation-at-a-time guard within one generation.

## Acceptance

- `stop` immediately followed by `start` installs forwarding rules without reporting a control-operation conflict.
- A control process from a superseded launch cannot resume, fail, or time out the current launch.
- Every continuation resumes exactly once across normal completion, stop, cancellation, timeout, and launch failure.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
