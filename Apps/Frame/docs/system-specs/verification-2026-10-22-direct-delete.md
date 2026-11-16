# Direct Delete and keyboard verification

Date: 2026-10-22

## Version-label correction — 2026-10-22

Development-only release-version bumps were reverted and both apps rebuilt/reinstalled: Frame **0.1.0, build 10** and RelayBar **1.6.0, build 16**. Internal build numbers, bridge v4, features and preferences were retained. Both repositories now prohibit marketing-version changes for development/rebuild/install work without an explicit user request.

Installed signatures, architecture/dSYM checks, launch and the unchanged three-location bridge catalog were verified. Frame restored Downloads with 1,666 assets and its existing settings. Only version metadata and documentation changed; the source test results below remain from the preceding feature delivery, not a new test run. Build logs: `.build/version-correction-build.log` in each repository.

Corrected executable SHA-256: Frame `16e73ffc3463031de765273699a399683c19ae28c9dda0fa0d0ab3173ba35d24`; RelayBar `0e5537c511f45936e615b3706bdf3e445d3b87a71ff2ac316d8c4acdf9236374`. The displaced 0.6.1/10 and 1.8.1/16 bundles remain in Frame `.build/backups`. The delivery record below preserves the labels/hashes used at the time.

## Installed delivery

- `/Applications/Frame.app`: 0.6.1, build 10, arm64, macOS 14 minimum.
- `/Applications/RelayBar.app`: 1.8.1, build 16, arm64/x86_64, macOS 13 minimum.
- Bridge v4; mirrored wire sources byte-identical. Legacy trash requests are unsupported, never reinterpreted as delete.
- Both installed bundles pass deep/strict signature checks with timestamped hardened-runtime Developer ID team `39HYFR5Z65`. RelayBar's nested Sparkle checks and executable/dSYM UUIDs match. Local delivery only; no notarization, publication, commits or pushes.
- Previous bundles retained in Frame `.build/backups/Frame-0.6.0-build9-2026-10-22.app` and `RelayBar-1.8.0-build15-2026-10-22.app`. Preferences retained.

Installed executable SHA-256:

```text
Frame     5464317b8c83ea40ed2ad50a9cb521743ae21aaee00c754d61c3fd27b1bc5f62
RelayBar  0ba557c04477cc91c020aab41fb449e467717baa84a55b21dccd0a3d97267333
```

## Automated checks

- Frame: `swift test`, 82 passed, zero failures.
- RelayBar: `FRAME_HELPER_PYTHON=~/.local/share/mise/installs/python/3.12.12/bin/python3 swift test -Xswiftc -warnings-as-errors`, 348 executed, 326 passed, 22 opt-in/live/visual tests skipped, zero failures.
- Regressions cover direct paired unlink, unselected files, stale files, symlinks, Archive deletion, Archive/Restore collisions and rollback, partial-delete error reporting, no new permission gate, history isolation, immediate batch/singular store actions, and viewer arrow/Delete key mapping.
- Source search finds no remote Trash, remote Undo, write-permission gate or generic collection-kind fields. Local macOS Trash remains unchanged.
- Logs: `.build/delete-shortcuts-tests.log` and `.build/delete-shortcuts-release.log` in each repository. RelayBar `git diff --check` passed.

## Installed native checks

Using three generated local images plus one paired JSON, not user photos:

- Enlarge then Right advanced from red to green; on-screen Next advanced to blue.
- In macOS full screen, Left returned to green without leaving full screen.
- Plain Delete removed green and advanced to blue while remaining full screen.
- Clicking metadata did not disable Right-arrow navigation.
- Contact-sheet plain Delete removed the red image and its paired JSON; filesystem inspection confirmed both absent. Local Undo restored all fixture files.
- Frame's Open sheet read the unchanged three RelayBar remote locations, confirming installed bridge connectivity without opening a host.
- Returned Frame to Downloads: 1,666 assets, existing favorite and 360 pt thumbnail preference retained.

Permanent remote deletion was exercised only by the helper on disposable test files, with store/bridge routing tested separately. No private host was opened or mutated. Existing remote `.FrameTrash` contents were not purged. Network interruption and concurrent-writer behavior are not claimed atomic.
