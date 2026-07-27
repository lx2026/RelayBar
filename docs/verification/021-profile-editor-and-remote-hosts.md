# Task 021 Verification

Date: 2026-07-26

Result: Complete.

## Automated checks

- `swift test -Xswiftc -warnings-as-errors` passed 163 tests with 12 opt-in
  tests skipped and no failures.
- The new coverage verifies bounded OpenSSH-config reading and parsing,
  cross-source ordering and deduplication, standalone-host validation and
  persistence, removal isolation, bounded recents, success-only promotion, and
  opening a standalone host without a forwarding profile.
- The unsigned Release app build passed:

  ```sh
  xcodebuild -quiet -project RelayBar.xcodeproj -scheme RelayBar \
    -configuration Release -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO build
  ```

- `plutil -lint RelayBar.xcodeproj/project.pbxproj Packaging/Info.plist`
  passed.
- `git diff --check` passed.

## Visual evidence

`VisualSnapshotHarness/testCaptureTask021Snapshots` passed and rendered the
New Profile editor at 380 × 440 points and the Remote Files launcher at
360 × 300 points in both Aqua and Dark Aqua.

- New Profile retained 16-point horizontal content padding, kept Quick Add
  inside the window, showed the connection fields without left-edge clipping,
  and displayed one Group label.
- Remote Files showed the standalone server picker plus compact Add Host and
  Remove Saved Host controls without clipping or colliding helper text.
- The four generated PNGs were inspected from a temporary snapshot directory;
  they are verification output and are not tracked repository assets.

## Behavioral and security evidence

- `testStandaloneHostOpensWithoutAForwardingProfileAndBecomesRecent` proves a
  saved `user@server` target reaches the existing Remote Files browser without
  creating a forwarding profile.
- `testFailedStandaloneOpenDoesNotBecomeRecent` proves failed connections do
  not mutate the recent list.
- `testRemovingStandaloneHostLeavesForwardingProfilesAvailable` proves removal
  is limited to the standalone catalog.
- Config parsing reads no more than 1 MiB, caps concrete aliases at 256, and
  rejects wildcard, character-pattern, negated, malformed, and oversized
  inputs. RelayBar does not write OpenSSH config.
- Existing SFTP, navigation, preview, download, cancellation, and
  forwarding-profile tests passed unchanged. Live SSH tests remained skipped
  because their opt-in environment was not configured; no new live-SSH
  behavior is introduced below the already-tested `RemoteFileServing`
  boundary.

No commit, push, release, notarization, publication, or deployment was
performed.
