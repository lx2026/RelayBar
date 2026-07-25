# Task 012 — Cheapen Syntax Highlight Cache Lookups

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`RelayBarCodeSyntaxHighlighter.highlightCode` builds its cache key as `"\(appearanceKey)|\(language)|\(code)"`, copying and hashing the entire code block — up to 64 KB — on every lookup, including cache hits. The method is a SwiftUI render callback, so this happens on the main thread during rendering.

## Delivery Boundary

### Included

- A bounded cache key that does not scale with block length.

### Excluded

- Moving highlighting off the main thread. `CodeSyntaxHighlighter` is a synchronous rendering callback; changing that is a larger redesign and stays out of this task.

## Work

- Derive the key from a fixed-size digest of appearance, language, and code rather than the code text itself.
- Keep both the success cache and the failure cache keyed consistently.
- Preserve the existing size limit, language normalization, and locking behavior.

## Acceptance

- Cache key construction is independent of code-block length.
- Highlighted output, unsupported-language fallback, and over-limit fallback are unchanged.
- Light and dark highlighters remain independently cached.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
