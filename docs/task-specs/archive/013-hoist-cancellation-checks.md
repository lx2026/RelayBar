# Task 013 — Hoist Cancellation Checks Out of Leaf Scanners

Status: Withdrawn

Created: 2026-07-24

Withdrawn: 2026-07-25

## Withdrawal

The cost this task removed is not measurable in context. It was implemented, committed to the branch, then reverted.

### What the task claimed

That `Task.isCancelled` in the innermost character loops of `ObsidianMarkdownCompatibility` is "a concurrency-runtime call, paid per character" across documents up to 2 MB, and that removing it from six leaf scanners was worth doing.

### What was measured

`PerformanceClaimTests.testMarkdownScannerCosts`, release build:

- `Task.isCancelled` costs **2.2 ns** per check. The debug build reports 127 ns, which is what made the checks look expensive when reasoned about rather than measured.
- `renderSource` over a 776 KB document takes **≈1.0 second**.

Even assuming a check for every character on every pass, the removed checks account for well under 1% of that render. The change bought roughly 7 ms on a document that takes a second.

### Resolution

Reverted. All six leaf scanners have their cancellation checks back, restoring the file to its original 30 check sites. Output was identical either way, so nothing else changes.

### What this did surface

The real number here is the second. `renderSource` costing ≈1.0 s for 776 KB is roughly 150 times larger than anything the cancellation checks contribute, and it is the finding worth acting on: the pipeline makes several full passes and re-materializes `[Character]` arrays per line on each. That is a separate, larger piece of work and is deliberately not attempted here.

### What went wrong in the process

The per-character cost was estimated, not measured, and the estimate was taken from intuition about runtime calls. Measuring first would have shown both that the target was negligible and where the actual cost lives.
