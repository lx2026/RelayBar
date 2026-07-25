# Task 010 — Compile the PermitRemoteOpen Expression Once

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`SSHArgumentPolicy.isValidPermitRemoteOpenDestination` builds an `NSRegularExpression` on every call. In the editor, `builtTunnel` validates each destination and then `isSafeToRun` validates them all again, so the expression is compiled twice per destination for every keystroke. `ObsidianMarkdownCompatibility` already holds its expression in a `static let`; apply the same treatment.

## Work

- Hoist the destination pattern into a type-level compiled expression.
- Keep the existing validation semantics, including the full-range match requirement and the port bounds check.

## Acceptance

- The expression is compiled once per process, not per call.
- Accepted and rejected destination values are unchanged, including `*` ports, bracketed IPv6 hosts, and out-of-range ports.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
