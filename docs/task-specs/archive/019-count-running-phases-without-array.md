# Task 019 — Count Running Phases Without an Intermediate Array

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`TunnelStore.runningCount` filters `phases.values` into a new array only to read its count. It is read from both the menu-bar label and the list header, so it runs on every state publish. `count(where:)` expresses the same thing without the allocation.

## Work

- Replace the filter-then-count with a direct predicate count.

## Acceptance

- The count is unchanged for stopped, starting, retrying, running, and failed phases.
- The menu-bar icon and header activity text still track it.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
