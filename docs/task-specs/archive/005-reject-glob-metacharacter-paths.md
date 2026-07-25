# Task 005 — Reject Remote Paths That sftp Would Glob

Status: Withdrawn

Created: 2026-07-24

Withdrawn: 2026-07-25

## Withdrawal

The finding behind this task was wrong, and the change it produced was a regression. It was implemented, committed to the branch, then reverted in full. The record is kept so the same mistake is not repeated.

### What the task claimed

That `RemotePath.batchQuoted` escapes only `\` and `"`, which satisfies the sftp tokenizer but not its globber, so a remote path containing `*`, `?`, or `[` would be expanded rather than used literally. The claim rested on one sentence in `sftp(1)`: "Any special characters contained within pathnames that are recognized by glob(3) must be escaped with backslashes".

### What is actually true

That sentence describes unquoted arguments. sftp's own quoting already suppresses expansion: inside a quoted argument it escapes glob metacharacters before matching, so they resolve literally. Measured against OpenSSH 10.2 over a real connection, using `batchQuoted` output verbatim:

| Remote path | Result |
| --- | --- |
| `"…/report[2026]"` | listed correctly, not treated as a character class |
| `"…/draft?.md"` | listed correctly |
| `"…/star*dir"` | listed correctly |
| `"…/bra[ck]et.md"` | listed correctly |
| `"…/quo\"te.md"` | listed correctly |
| `"…/back\\slash.md"` | listed correctly |
| `"…/*"` | reported not found, having been escaped to a literal `\*` |

The last row is the direct evidence: sftp inserted that backslash itself. Quoting was already doing the job this task assumed it was not.

### Consequence

The refusal shipped by this task blocked remote paths that already worked. Any folder or file named with a bracket, star, or question mark became unopenable through RelayBar, having been fine before. The unit tests written for the task passed because they asserted the new refusal rather than the underlying sftp behavior, which no test or manual check had ever exercised.

### Resolution

Every code change from this task was reverted: the metacharacter set, `containsGlobMetacharacters`, `remoteBatchQuoted`, the `structuralValidationMessage` split, the `unsupportedPathCharacters` error, and the command-builder and service guards. `batchQuoted` now carries a note recording the measured behavior, so the escaping is not "fixed" again. Task 020, which existed only to carry the deferred escaping, was deleted.

Tests pin the correct behavior instead: `RemotePathTests` and `SFTPCommandBuilderTests` assert that metacharacter paths are accepted and quoted, and `LiveLoopbackTests` lists and opens real `report[2026]` and `star*dir` directories over a real connection.

### What went wrong in the process

The finding was reasoned from a man-page sentence rather than measured, and this task's own delivery boundary then excluded the measurement as something that "cannot be accepted on unit tests alone". That exclusion should have blocked the task rather than justified shipping a guess. A behavior claim about a third-party tool needs evidence from that tool before any code depends on it.
