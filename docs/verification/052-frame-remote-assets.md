# Task 052 verification

Date: 2026-10-22
Installed: RelayBar 1.8.0/15, universal; Frame 0.6.0/9, arm64; bridge v3.

## Checks

RelayBar: 346 tests executed, 324 passed, 22 pre-existing opt-in/live/visual skips, zero failures, warnings as errors. Frame: 78 passed, zero failures. Helper tests used disposable synthetic media/JSON and a local SSH-executable stand-in; no private host was contacted.

Covered paired archive/trash/restore, Archive → Trash, collision refusal, stale same-sized files, traversal/symlinks, unmanaged directories, malicious manifests, rollback after second-member failure, image/video derivatives and metadata, conditional reuse, fixed-code/stdin transport, separate write consent, JSON ownership, passive history and expired-listing renewal. Frame additionally verifies persistent caching across clients, deduplication, eviction and no implicit original fallback.

Synthetic 4000 × 2250 JPEG: 8,819,363 original bytes → 13,435 preview bytes; 0.250 seconds local generation. This excludes SSH and is not a private-host performance promise.

## Signed installation

Both build scripts completed. Installed strict deep signatures passed, with Developer ID Thought Tides LLC (39HYFR5Z65), hardened runtime and retained entitlements. Nested Sparkle signatures remain valid. RelayBar executable/dSYM UUIDs match for both architectures.

RelayBar SHA-256: 861df1622f112b4189b996e2c63f6159380bf662d681dd7a7b5a3d9ce68486ff.
Frame SHA-256: add0d2cd7faeeda43a2238c67860a0aabb30e73f940969a44b98443b56e80657.

Both final apps launched. Frame restored its local library and read RelayBar's three retained locations through the authenticated installed bridge. This read did not alter history. Previous apps remain recoverable under the Frame repository's .build/backups. Preferences, SSH setup and source files were preserved.

Logs: .build/remote-assets-tests.log, .build/remote-assets-helper-tests.log, .build/remote-assets-release.log. git diff --check passed; mirrored wire files match.

## Not claimed

Real private-host latency/dependencies, first native write-consent interaction, remote native batch/fullscreen/URL-handoff flow, arbitrary filesystem support and every interrupted-transaction boundary remain manual acceptance. No private-host mutation test was performed. No commit, push, PR, notarization or public publication. Public channels remain 1.6.0/11; Task 032 is unchanged.
