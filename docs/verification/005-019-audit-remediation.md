# Tasks 005–019 — Audit Remediation Verification

Verified: 2026-07-25

Result: Complete for twelve of the fifteen tasks. **Tasks 005, 012, and 013 were withdrawn** after testing showed their findings did not hold; all three were reverted in full. Each carries its own withdrawal record: [005](../task-specs/archive/005-reject-glob-metacharacter-paths.md), [012](../task-specs/archive/012-cheapen-highlight-cache-lookups.md), [013](../task-specs/archive/013-hoist-cancellation-checks.md).

These fifteen tasks came from one review pass over the app sources for reliability, performance, and conciseness. They share this report rather than repeating the same command output fifteen times.

## Automated evidence

- `swift test` passed 150 tests with 11 opt-in tests skipped and no failures, up from 133 before the change. With `RELAYBAR_LOOPBACK_SSH_DIR` set, the two live tests also pass against a real OpenSSH server.
- `swift test -Xswiftc -warnings-as-errors`, the first CI check, passed.
- The Release app build, the second CI check, succeeded:

  ```sh
  xcodebuild -project RelayBar.xcodeproj -scheme RelayBar \
    -configuration Release -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO build
  ```

- The Debug build with complete Swift concurrency checking passed with no new concurrency diagnostics.
- `plutil -lint Packaging/Info.plist` and `git diff --check` passed.

### New coverage

- **Glob metacharacters (formerly Task 005).** `RemotePathTests` and `SFTPCommandBuilderTests` assert that paths containing `*`, `?`, and `[` are accepted and quoted without extra escaping. `SFTPListingParserTests` covers a listing whose entries carry those characters. These pin the behavior the withdrawn task broke.
- **Task 007.** `testRestartIsNotBlockedByAStoppedLaunchesControlOperation` starts a profile, stops it while its control operation is still in flight, and restarts immediately. The fake SSH fixture gained `RELAYBAR_FAKE_SSH_IGNORE_TERM_SPEC`, a forward that ignores `SIGTERM`, so the stopped launch's operation is guaranteed to outlive the restart.

  This test was confirmed to be a regression test, not a tautology: with the per-operation guard temporarily reverted to the previous per-profile guard, it fails with `Restart failed: Another SSH control operation is still running. Automatic retry stopped after 1 attempts.` — the exact defect Task 007 describes.
- **Task 008.** `testCancellationStopsTheProcessAndRemovesPartial` records a cooperative child's signals and verifies `SIGTERM` is delivered without the delayed `SIGKILL`. `testCancellationForceStopsAProcessThatIgnoresTermination` verifies a stubborn child receives exactly one `SIGTERM` and one `SIGKILL`, the continuation resolves as cancellation, and partial data is removed. Both paths passed 30 consecutive final iterations.
- **Task 009.** `testGroupingCacheInvalidatesOnEveryMutationPath` covers add, update, move, rename, ungroup, and delete, because the change introduces a cache whose only real risk is staleness.
- **Task 011.** `ProgressPollingIntervalTests` covers the fixed single-file interval, the 1-second directory floor, growth with entry count, and the 8-second bound.
- **Task 014.** `RemoteByteCountTests` asserts the reused formatter's output against `ByteCountFormatter` for twelve sizes, and pins the specific wording for 999 bytes, 1 KB, and 843 KB.

## Visual evidence

`VisualSnapshotHarness` renders `RelayBarRootView` offscreen at the fixed 380-by-440 menu size in light and dark appearance, using a mixed grouped fixture. It is skipped unless `RELAYBAR_SNAPSHOT_DIR` is set, following the same opt-in pattern as the live SSH tests.

- Both appearances render named sections in localized order with **Personal** before **Work**, saved order preserved inside each section, rows unchanged, and the Remote Files row and footer in place. This confirms Task 009 did not disturb section presentation.
- Screen capture of the running app was not available in this environment: `screencapture` failed with `could not create image from display`, so the evidence is offscreen rendering rather than a live window.

### Not visually covered

- Task 014's **Reveal Local Socket** item and Task 004's group menus live inside SwiftUI `Menu` content, which is not built until the menu opens and cannot be driven by offscreen rendering.

### Coverage carried by existing tests

- **Task 006** and **Task 016** are exercised by the existing control-forward suite, including the failure and timeout paths, which assert the output and error text a control operation returns.
- **Task 015** is exercised by `testNormalizesActionableConnectionErrors`. Its host-key expectation was updated for the apostrophe correction that task specifies; every other mapping is unchanged.
- **Task 018** is proved by the build: the removed accessors have no remaining caller. Test references to `browserURL` were redirected to `unambiguousBrowserURL`, the property the app actually calls, and the `forwardArguments` assertion now composes `rules.flatMap(\.sshArguments)` directly.
- **Tasks 010, 014, 017, and 019** preserve observable behavior exactly; the existing suites for argument policy, remote-file rows, master stderr retention, and running counts cover them unchanged.

## Review notes

- Task 009's cache is invalidated from a `didSet` on the saved list, so every mutation path clears it, including in-place subscript assignment. The initial value assigned in `init` does not need invalidation because the cache starts empty.
- Task 007 keeps the single-operation-at-a-time rule; it is now scoped to a launch generation rather than a profile. Continuations still resume exactly once on completion, stop, cancellation, timeout, and launch failure, because a superseded operation stays registered until its own termination handler runs.
- Task 008 now launches the SFTP child directly and owns its exit observation and `waitpid`. Reaping and signal delivery share one lock: if the child exits immediately before escalation, it remains an unreaped zombie until the signal attempt finishes, so its PID cannot be reassigned to an unrelated process. The child starts with default, unblocked signal handling to preserve cooperative `SIGTERM` cancellation.
- Task 006's handler detachment happens before the synchronous drain, and the operation is removed from the registry first, so a handler block still in flight becomes inert instead of recreating a buffer. Control output stays on the main queue rather than hopping through a `Task`, which preserves FIFO ordering with the termination handler's dispatch.
- Reviewing that rewrite surfaced a pre-existing latent hang on the same path: the drain also ran when `Process.run()` itself threw. No child ever held those pipes' write ends in that case, so `readDataToEndOfFile` would wait on the main queue for an end of file that cannot arrive. The drain is now skipped when the launch failed, where there is nothing to read anyway.
- Task 014 replaced a filesystem probe in a menu builder with a shape test. Reveal now falls back to the enclosing folder when the socket is gone, which is a small behavior change in the stale case and is recorded in the tunnel-management spec.
- Task 014's first implementation used `.formatted(.byteCount(style: .file))` and was wrong: that style renders SI `kB` where `ByteCountFormatter` renders `KB`, and rounds 999 bytes up to `1 kB`, so every kilobyte-sized row would have changed wording. The spec asserted the text was unchanged and the task was marked complete without checking it. The automated suite could not catch this because nothing asserted the row text. It now reuses one main-actor-confined `ByteCountFormatter`, which meets the same goal with identical output, and `RemoteByteCountTests` pins the equivalence.
- No dependency, asset, entitlement, or persisted format changed. The only user-visible string change that survives is Task 015's apostrophe correction; Task 005's refusal message was reverted with the rest of that task.

## Measured performance evidence

`PerformanceClaimTests` runs the previous and current shape of each performance change in one process. It is skipped unless `RELAYBAR_BENCH` is set. Release build, Apple silicon:

| Task | Before | After | Verdict |
| --- | --- | --- | --- |
| 009 grouping per render, 24 profiles, 4 sections | 286.8 µs | 56.6 µs | **5.1× faster**, kept |
| 010 PermitRemoteOpen validation | 7.78 µs | 3.77 µs | **2.1× faster**, kept |
| 011 progress poll, 5,000-file tree | 22.9 ms per poll every 1 s | same poll every 5 s | **5× less walking**, kept |
| 012 highlight cache key, 1 KB / 16 KB / 64 KB | 0.17 / 0.43 / 2.15 µs | 30.8 / 36.9 / 59.4 µs | **28–179× slower, withdrawn** |
| 013 leaf cancellation checks | `Task.isCancelled` = 2.2 ns | ≈7 ms saved on a 1.0 s render | **under 1%, withdrawn** |

Two conclusions follow. The three kept changes are worth their diff, measured rather than assumed. The two withdrawn ones were justified by reasoning that measurement contradicted: a digest must read every byte where `NSString` bridging is lazy, and a 2.2 ns check is not a per-character cost worth removing.

The same run surfaced a finding this branch does **not** address: `renderSource` takes ≈1.0 second for a 776 KB document, roughly 150 times more than everything Task 013 targeted. The markdown pipeline's repeated full passes and per-line `[Character]` materialization are the real cost there, and reworking them is separate, larger work.

## Live evidence

`LiveLoopbackTests` runs the real `/usr/bin/ssh` and `/usr/bin/sftp` paths against a throwaway `sshd` bound to `127.0.0.1:2222` with its own host and client keys. It is skipped unless `RELAYBAR_LOOPBACK_SSH_DIR` is set. Against OpenSSH 10.2 it confirms:

- A profile with a local TCP forward and a port-`0` remote rule reaches running, OpenSSH reports a real allocated port, and an HTTP request through the forward returns 200 with the expected body.
- Stop followed immediately by start reaches running again, allocates a fresh port, and still carries traffic. This is the Task 007 path against genuine OpenSSH reaping timing rather than the fake fixture's.
- A real directory listing retains `report[2026]`, `draft?.md`, and `star*dir` rows, and each of those directories opens correctly — the evidence that withdrew Task 005.

The setup ran as an unprivileged process on loopback and was torn down afterwards; `~/.ssh/known_hosts` was restored from a byte-for-byte backup. No system or security setting was changed.

No release, notarization, publication, or deployment was performed.
