# Task 013 — Hoist Cancellation Checks Out of Leaf Scanners

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`ObsidianMarkdownCompatibility` checks `Task.isCancelled` inside its innermost character loops, including `repeatedCount` and `isEscaped`. Each check is a concurrency-runtime call, paid per character, across documents up to the 2 MB decoder limit and repeated over several scanning passes.

Rendering already runs in a detached task off the main thread, and every leaf scanner is reached from a loop that polls cancellation once per line. The leaf checks are therefore redundant.

## Delivery Boundary

### Included

- Leaf scanners bounded by one run, one token, or one line, reached from a loop that already polls per line: `repeatedCount`, `isEscaped`, `escapeMarkdownText`, `codeSpan`, `firstCharacter`, `firstUnescapedCharacter`.

### Excluded

- The per-character checks in the main scanners `stripCommentSegments` and `transformInline`. Those bound the work inside a single line, which matters because one line may be the whole document; removing them would trade a real cancellation-latency regression for a small constant.
- Every per-line and per-pass check, and the checks in scanners whose lookahead crosses lines.

## Work

- Remove the cancellation check from each in-scope leaf scanner.
- Record why those scanners carry no check, so the omission is not read as an oversight.
- Leave budgets, bounds, and returned values otherwise unchanged.

## Acceptance

- No cancellation check remains in the six leaf scanners named above.
- Every retained check still sits on a path that observes cancellation at least once per line.
- Rendered output is unchanged for the existing Markdown fixtures.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
