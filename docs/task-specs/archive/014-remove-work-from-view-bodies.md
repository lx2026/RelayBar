# Task 014 — Remove Formatter and Filesystem Work From View Bodies

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

Two view bodies do work that does not belong in a render pass:

- `RemoteFilesView` formats every row's size through `ByteCountFormatter.string(fromByteCount:countStyle:)`, which constructs a formatter per call.
- `TunnelRow`'s menu builder calls `FileManager.default.fileExists` to decide whether to offer **Reveal Local Socket**, putting a synchronous filesystem `stat` in a body that re-evaluates on every phase change.

## Work

- Reuse one `ByteCountFormatter` instead of building one per row. The `.formatted(.byteCount(style: .file))` style is **not** a substitute: it renders SI `kB` where `ByteCountFormatter` renders `KB`, and rounds 999 bytes up to `1 kB`. Output must stay identical, so the reused instance is confined to the main actor, which every caller already is.
- Move the socket-existence check out of the body: offer the action based on the rule's own shape and let the reveal handler deal with an absent socket.

## Acceptance

- Row size text is unchanged for zero, sub-kilobyte, kilobyte, and multi-gigabyte sizes, asserted directly against `ByteCountFormatter` output rather than assumed.
- No filesystem call remains in a SwiftUI body or menu builder.
- **Reveal Local Socket** still appears only for local Unix-socket rules, and does nothing harmful when the socket is gone.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
