# Task 009 — Build Tunnel Grouping Once Per Render

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`TunnelListView.body` computes `store.grouping`, and every `groupHeader` then calls `store.groupNames`, which constructs a second, third, and further `TunnelGrouping` — each one bucketing all saved profiles and sorting with `localizedStandardCompare`. The body re-evaluates on every `phases` and `runtimePorts` publish, so this repeats on each retry tick. The row path at the same call site already threads `grouping.groupNames` through; only the header path was missed.

Task 004 requires section derivation to cost `O(n + g log g)`; rebuilding it per section breaks that guarantee in the view layer.

## Work

- Pass the already-computed group names into `groupHeader` instead of reading `store.groupNames` inside it.
- Confirm no other view body constructs `TunnelGrouping` more than once per evaluation.

## Acceptance

- One `TunnelGrouping` is constructed per list body evaluation regardless of section count.
- Section order, names, rename, and ungroup behavior are unchanged.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
