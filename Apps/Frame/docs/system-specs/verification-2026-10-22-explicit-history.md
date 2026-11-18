# Explicit remote history verification

Date: 2026-10-22. Delivered: Frame 0.5.1/7 and RelayBar 1.7.1/13.

## Behavior and tests

- `swift test -Xswiftc -warnings-as-errors`: Frame 73 tests, zero failures. RelayBar 334 tests, 22 opt-in live/snapshot skips, zero failures (312 passed).
- Frame regressions cover tree expansion and recursive scans without recording, explicit cached opens without another loader call, Refresh without promotion, parent navigation, empty-folder opens, failed/superseded/hidden opens and history-write failure retaining the view.
- The real client renewal tests confirm stale thumbnail listings are renewed without a `rememberOpen` request. The broker test performs 64 descendant listings plus a refresh with unchanged recents/notifications, then verifies explicit promotion, stable location identity, deduplication and persistence reload.
- Consent, unknown hosts, invalid paths, cancelled/failed lists and both old/future protocol versions are guarded. Both wire copies are byte-identical. Protocol v2 prevents old/new pairs from issuing v1's history-mutating lists.
- History recording is deliberately a separate local request, not an SSH operation or listing-cache side effect. The authenticated viewer is responsible for sending it only after successful explicit opens. It requires a known host and validated absolute path but does not re-check folder existence over SSH.

## Builds and installation

Both existing release build scripts succeeded. Property-list lint, RelayBar project lint and `git diff --check` passed. The existing RelayBar feature branch `codex/frame-viewer-handoff` has no upstream and is based on `5ebcfdd`, equal to fetched `origin/main` (0 ahead/behind). Existing Task 050 working changes were retained; no commit or push was made. Frame has no Git repository.

Both bundles have timestamped hardened-runtime Developer ID signatures from Thought Tides LLC (`39HYFR5Z65`), and strict/deep verification passed before and after installation. Frame retains its sandbox/bookmark/user-selected-file/network-client/App Group entitlements. RelayBar retains its App Group and inside-out signed Sparkle components. Frame is arm64, macOS 14+; RelayBar is x86_64/arm64, macOS 13+. RelayBar dSYM UUIDs match the executable: x86_64 `441197B0-851F-3D88-9CAF-80F304EE763C`, arm64 `F2D137A9-7992-3BAB-8257-7EB81B1F125E`.

Installed executable SHA-256 (identical to corresponding build output):

| App | SHA-256 |
| --- | --- |
| `/Applications/Frame.app` | `0c1e4c3259c5191e6c9f1e981884cd658240caea37fe9c0ece60169d70a622bc` |
| `/Applications/RelayBar.app` | `c261bb1247760fc4c8f0e343a195c4740765181a3e88710129bc7221b2d59950` |

Both apps quit normally via Command-Q and relaunched from Applications. Native Frame restored 1,666 local assets, the existing favorite, and the user's 100 pt thumbnail size. Opening its chooser successfully read the installed RelayBar v2 catalog without opening a host. Its five visible remote locations matched the leading five in RelayBar's pre-update UI observation. No history cleanup, preference reset, SSH configuration edit or private-media screenshot was performed.

Prior bundles are preserved intact under this project's `.build/backups/`:

- `Frame-0.5.0-build6-2026-10-22.app` — executable SHA-256 `31a523d3e1f4a838c63c8a798e8f47548fe14118574b911b712930d341fe6c02`.
- `RelayBar-1.7.0-build12-2026-10-22.app` — executable SHA-256 `7f3cc44937cc8a9c126e73b319bd608c1baeb2b3eb57b28d75a5e29db1b19919`.

## Limits

No notarization, public release, feed or website update. No new live-host scan, real-host performance measurement, Intel runtime or full URL handoff was exercised; existing broader acceptance remains open. macOS emitted unrelated Contacts helper diagnostics during passing tests and an out-of-date iOS simulator warning during the successful macOS build.

A defaults-key hash check could not read the catalog keys, so no storage-byte identity claim is made. An attempted automatic AX comparison had an empty diff baseline; the displayed five-location comparison used the earlier full UI observation instead. RelayBar's menu-bar-only AX attach timed out after launch, but the running process and successful authenticated catalog request confirm it started.
