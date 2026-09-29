# Task 045 — Configurable SSH Retries Verification

Verified: 2026-09-28

Result: Complete. Implements [issue #30](https://github.com/lx2026/RelayBar/issues/30).

## Scope and Git base

Work is on `codex/ssh-retry-settings`, created from
`1cc8c45815addd687ff330f89e9eac99505b1249`. After fetching origin, that base was
0 commits ahead of and 0 behind `origin/main`. Existing uncommitted Remote
Files work was preserved. No commit, push, or release was made.

## Automated evidence

- `swift test --filter TunnelStoreIntegrationTests -Xswiftc -warnings-as-errors`
  passed: 32 tests, 2 opt-in live tests skipped, no failures.
- `swift test -Xswiftc -warnings-as-errors` passed: 319 tests, 20 opt-in live,
  benchmark, and snapshot tests skipped, no failures.
- The fake-SSH fixture records exact master invocations: limits 0, 1, and 3
  produce respectively 1, 2, and 4 launches. Tests also verify persistence of
  0 and other limits, default 10, and bounds 0–100.
- Pending-limit tests cancel disabled or over-budget waits and prove no later
  launch occurs past the cancelled deadline. Allowed waits preserve their
  delay, count, and timer while publishing the new limit. Raising the limit
  does not restart an exhausted profile; a manual start does.
- Simulated monotonic time and real local fake-SSH processes verify that
  repeated 59-second connections exhaust the budget, a 60-second connection
  resets it, and a manual start resets it. Setting 0 while running leaves the
  connection intact and prevents retry after its next exit.
- Delay coverage verifies 5, 10, 20, 40, 80, 160, 300, 300… seconds and safe
  handling of extreme attempt values. Existing stop, rollback, group, and
  launch-generation tests continue to pass.
- The Xcode Debug app build passed using the app target's configured complete
  strict-concurrency and warnings-as-errors settings, with signing disabled.
  Invocation: `xcodebuild -project RelayBar.xcodeproj -scheme RelayBar
  -configuration Debug -derivedDataPath .build/Task045
  -clonedSourcePackagesDirPath .build/Task033StrictV2/SourcePackages
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build`.
- `sh -n Tests/Fixtures/fake-ssh.sh`, property-list lint for the app and Xcode
  project, and `git diff --check` passed.

The first Xcode invocation applied warnings-as-errors to dependency targets,
which conflicted with their warning-suppression options. The successful run
uses the existing app-target settings without overriding dependency settings.

## Visual evidence

With `RELAYBAR_SNAPSHOT_DIR=/tmp/relaybar-045-snapshots`, the two selected
`VisualSnapshotHarness` tests `testCaptureRetrySettingsSnapshots` and
`testCaptureTunnelListSnapshots` passed with no failures. The matrix covers
limits 0, 10, and 100 in Aqua and Dark Aqua, plus the existing Settings
confirmation and login-approval states. Assertions verify horizontal
containment and that normal Settings fits 380 × 440 without vertical scrolling.

Inspected the normal light, disabled-retry dark, and login-approval light
captures. The retry label, value, stepper, off explanation, backoff explanation,
and existing footer remain readable and reachable. The control declares an
accessibility label and value (Off or the retry count). The existing snapshot
comparison also verifies that update state does not change the tunnel list.

Reproducible captures and logs are temporary evidence under
`/tmp/relaybar-045-snapshots` and `/tmp/relaybar-045-*.log`.

## Lifecycle and live scope

Retry state stays per profile; only the global integer limit is persisted.
Remote Files does not gain background reconnects, and the SSH command policy
is unchanged. These delays do not impose an aggregate connection rate across
multiple profiles or other SSH clients.

No live SSH server or production banning policy was exercised. Timing and
failure verification used isolated local fake processes; opt-in live tests
remain skipped rather than claimed as passing.

## Local installation

At the user's request, the verified Debug build was signed with the existing
Developer ID identity, installed at `/Applications/RelayBar.app`, and launched.
Deep strict signature verification passed, and the installed executable matches
the signed staged executable with SHA-256
`5cb44d6ec3c7e04be257bcfb99666db57ba302a0f5118e555b932c50eef969a1`.
The previous app is preserved at `.build/RelayBar-before-045-install.app`.
