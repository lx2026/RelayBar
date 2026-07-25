# Task 020 — Escape Remote Paths That sftp Would Glob

Status: Active

Created: 2026-07-25

## Outcome

Make remote paths containing `glob(3)` metacharacters usable rather than refused. [Task 005](archive/005-reject-glob-metacharacter-paths.md) closed the silent-wrong-result hole by refusing `*`, `?`, and `[` in remote arguments; it deliberately stopped short of escaping them, because escaping changes the bytes reaching a third-party globber and cannot be accepted on unit tests alone.

## Delivery Boundary

### Included

- Backslash escaping of glob metacharacters in remote sftp arguments, replacing the refusal.
- Live-server evidence for the escaping form, including the interaction with the existing `\` and `"` escaping.

### Excluded

- Local destination paths, which sftp resolves literally.

## Work

- Determine, against a live server, how the sftp tokenizer's backslash handling composes with `glob(3)` for a path containing `*`, `?`, `[`, a literal backslash, and a double quote. `sftp(1)` states that glob-recognized characters must be escaped with backslashes, but the tokenizer also consumes backslashes, so the two interact.
- Replace the Task 005 refusal with escaping once the form is established, keeping the refusal as the fallback for anything the escaping cannot express.
- Cover the escaping form in unit tests and record the live evidence.
- Update the Remote Files system spec, which currently documents the refusal.

## Acceptance

- A folder named with each metacharacter, and one combining a metacharacter with a backslash and a quote, can be listed and downloaded against a live server.
- A path with no metacharacters produces the same command bytes as before.
- The refusal message no longer appears for paths the escaping handles.
- `swift test`, the warnings-as-errors build, and `git diff --check` pass.
- Live evidence is recorded in `docs/verification/020-escape-glob-metacharacter-paths.md`.
