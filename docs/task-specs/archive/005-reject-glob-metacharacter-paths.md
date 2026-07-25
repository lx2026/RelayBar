# Task 005 — Reject Remote Paths That sftp Would Glob

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

Stop presenting wrong results for remote paths that contain `glob(3)` metacharacters. `RemotePath.batchQuoted` escapes only `\` and `"`, which satisfies the sftp tokenizer but not its globber: `sftp(1)` states that "Any special characters contained within pathnames that are recognized by glob(3) must be escaped with backslashes". A directory literally named `report[2026]` therefore cannot be listed, and `/srv/a*` silently matches whatever else exists.

Until the escaping form is verified against a live server, RelayBar reports an explicit, actionable error instead of issuing a command whose result cannot be trusted.

## Delivery Boundary

### Included

- Detection of unescaped `*`, `?`, and `[` in any remote path sent to `sftp`.
- One clear user-facing message naming the unsupported characters.
- Listing entries whose names contain those characters remain visible; only navigating to or downloading them is refused.

### Excluded

- Backslash escaping that would make these paths work. That change alters bytes reaching a third-party globber and cannot be accepted on unit tests alone; it is deferred to Task 020 pending live-SSH evidence.

## Work

- Add a metacharacter check to `RemotePath` and apply it wherever a path becomes an sftp argument, covering both the typed path and entry paths derived from a listing.
- Surface the failure through the existing `RemoteFileError` presentation rather than a new alert path.
- Keep `batchQuoted`'s current `\` and `"` escaping unchanged so existing tokenizer coverage still holds.
- Cover accepted and rejected paths, including a `[` inside an entry name reached by activation rather than typing.

## Acceptance

- A path containing `*`, `?`, or `[` is refused before any process launches, with a message naming those characters.
- Paths without metacharacters behave exactly as before, and existing `batchQuoted` tests pass unchanged.
- A listing containing `report[2026]` still renders the row; activating it reports the refusal instead of opening the wrong directory.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
