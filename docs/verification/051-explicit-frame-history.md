# Task 051 — explicit Frame history verification

Date: 2026-10-22. Local RelayBar 1.7.1/13, Frame 0.5.1/7; bridge v2.

## Verification

- Full `swift test -Xswiftc -warnings-as-errors`: 334 tests executed, 22 opt-in live/snapshot skips, zero failures (312 passed). Frame: 73 passed, zero failures.
- Broker regression: 64 descendant listings and refresh do not add/promote recent paths or emit history notifications. Explicit `rememberOpen` promotes/deduplicates, retains location UUID, persists across catalog reload and does not list over SSH. Failed/cancelled reads leave existing history unchanged.
- Consent, unknown source, malformed path and v1/future protocol requests cannot write history. Frame tests cover scan/expansion/refresh/thumbnail renewal versus explicit cached, empty and parent opens; failed/superseded/hidden navigation is not recorded.
- Wire files are byte-identical. Plist/project lint and `git diff --check` passed. The existing `codex/frame-viewer-handoff` feature branch has no upstream; its base `5ebcfdd` equals fetched `origin/main` (0 ahead/behind). All prior Task 050 work was preserved. No commit or push.
- Universal Release build passed with existing strict app-target settings. Outer/nested signatures verify with timestamped hardened runtime and Developer ID Thought Tides LLC (`39HYFR5Z65`); App Group retained. x86_64 and arm64 executable/dSYM UUIDs match: `441197B0-851F-3D88-9CAF-80F304EE763C` and `F2D137A9-7992-3BAB-8257-7EB81B1F125E`.

## Installation

Both apps accepted Command-Q and were replaced from verified staged bundles with the old apps retained. Installed exact bundle/team checks passed across all architectures. Both processes are running from Applications, and installed Frame successfully read the RelayBar v2 shared catalog without opening any host. Existing first five remote rows matched the earlier pre-update UI observation. Frame restored its local library and thumbnail preference.

Installed executable SHA-256:

- RelayBar: `c261bb1247760fc4c8f0e343a195c4740765181a3e88710129bc7221b2d59950`.
- Frame: `0c1e4c3259c5191e6c9f1e981884cd658240caea37fe9c0ece60169d70a622bc`.

Each matches its build output. Prior bundles are preserved in the previous Frame working folder at:

- `.build/backups/RelayBar-1.7.0-build12-2026-10-22.app` — executable SHA-256 `7f3cc44937cc8a9c126e73b319bd608c1baeb2b3eb57b28d75a5e29db1b19919`.
- `.build/backups/Frame-0.5.0-build6-2026-10-22.app` — executable SHA-256 `31a523d3e1f4a838c63c8a798e8f47548fe14118574b911b712930d341fe6c02`.

No history clearing, preference reset, SSH configuration edit, notarization, publication or update-feed change. Public stable remains 1.6.0/11. No new live-host traversal or full native URL handoff test was performed; broader Task 050 acceptance stays open. Tests emitted unrelated Contacts helper diagnostics and the successful macOS build warned about unavailable iOS simulators. A defaults-key hash check was unavailable; the history-preservation observation is UI-based, not storage-byte verification.
