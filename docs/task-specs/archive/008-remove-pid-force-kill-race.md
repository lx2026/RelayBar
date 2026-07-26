# Task 008 — Remove the PID-Based Force-Kill Race

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`SFTPRemoteFileService.ProcessBox.cancel` schedules `Darwin.kill(processIdentifier, SIGKILL)` two seconds after `terminate()`. The `isRunning` check immediately before the signal makes misfires unlikely, but it is still a time-of-check/time-of-use gap against a recycled PID: the signal can reach an unrelated process. Close the gap without losing the escalation that stops a wedged `sftp`.

## Work

- Own child-process reaping and serialize it with signal delivery so the PID cannot be recycled between an exit check and escalation.
- Skip the escalation entirely once the process has been reaped.
- Keep the two-second delay and the single-escalation guarantee for a process that genuinely ignores `SIGTERM`.

## Acceptance

- A process reaped after `SIGTERM` is never sent `SIGKILL`, and no signal can reach a recycled PID.
- A process still running after the delay is still force-stopped exactly once.
- Cancellation still resolves the pending continuation for both paths.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
