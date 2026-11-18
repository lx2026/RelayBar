# Task 053 verification

Date: 2026-10-22

2026-10-22 correction: development-only marketing labels were reverted to RelayBar 1.6.0/16 and Frame 0.1.0/10, then rebuilt/reinstalled without feature changes. [Task 054](054-development-version-correction.md) has current installed hashes and evidence. The record below retains the original delivery labels.

Installed `/Applications/RelayBar.app` 1.8.1/16 and `/Applications/Frame.app` 0.6.1/10, bridge v4. Both apps pass strict/deep Developer ID signature checks. RelayBar is universal; Frame is arm64. Nested Sparkle checks passed. Previous app bundles are retained in the Frame repository's `.build/backups`; settings were preserved. No public release, notarization, commit or push.

RelayBar executable SHA-256: `0ba557c04477cc91c020aab41fb449e467717baa84a55b21dccd0a3d97267333`.

Executable/dSYM UUIDs match: x86_64 `8849AE49-7565-3B81-8D24-5BB310F709DA`, arm64 `777AB524-14B4-382C-B1FC-824DC14D5BE7`.

`FRAME_HELPER_PYTHON=~/.local/share/mise/installs/python/3.12.12/bin/python3 swift test -Xswiftc -warnings-as-errors`: 348 tests, 326 passed, 22 opt-in/live/visual skips, zero failures. Frame: 82 passed. Logs in each repository: `.build/delete-shortcuts-tests.log`, `.build/delete-shortcuts-release.log`. `git diff --check` and mirrored-wire comparison passed.

Disposable helper tests verify paired permanent deletion without new files/directories, unselected files retained, stale/symlink refusals, Archive deletion, partial failure reporting and unchanged Archive/Restore. Broker tests verify no extra permission prompt and no RelayBar history writes. Frame tests cover immediate batch deletion and full-size navigation/key routing.

Installed Frame native checks passed for arrow buttons/keys, full-screen continuity, metadata-focus navigation, and plain Delete in both contact sheet and viewer using generated local fixtures. Local Undo restored those fixtures. Open… displayed the same three remote locations through the new bridge; no host was opened. Frame was returned to Downloads with its existing 1,666 assets/favorite/360 pt thumbnail setting.

Private-host deletion, interruption boundaries and concurrent network-filesystem mutations remain untested. No existing remote `.FrameTrash` folder was purged. This task does not alter RelayBar's own pending-delete strip.
