# Task 017 — Name the Master Error Buffer Limit

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`TunnelStore.appendMasterError` trims to a literal `16_384` while the parallel control path trims to the named `controlOutputLimit`. Two bounds that serve the same purpose should be equally discoverable.

## Work

- Introduce a named constant for the master stderr bound alongside `controlOutputLimit` and use it at the trim site.
- Keep the current value so retained diagnostic text is unchanged.

## Acceptance

- No numeric literal remains at the trim site.
- The retained tail of master stderr is the same size as before.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
