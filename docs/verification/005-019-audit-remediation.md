# Tasks 005–019 — Audit Remediation Verification

Verified: 2026-07-25

Result: Complete

Every acceptance criterion in Tasks 005–019 has current evidence. Task 005 explicitly excludes the escaping that would make glob-bearing paths work; that is [Task 020](../task-specs/020-escape-glob-metacharacter-paths.md), which remains active and gated on live-SSH evidence.

These fifteen tasks came from one review pass over the app sources for reliability, performance, and conciseness. They share this report rather than repeating the same command output fifteen times.

## Automated evidence

- `swift test` passed 140 tests with 3 opt-in live tests skipped and no failures, up from 133 before the change.
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

- **Task 005.** `RemotePathTests` covers refusal of `*`, `?`, and `[` in remote paths, acceptance of the same characters in a local destination, and shape-only validation still accepting them. `SFTPCommandBuilderTests` covers refusal in the remote argument of `ls` and `get` while the local argument is quoted normally. `SFTPListingParserTests` covers a listing whose entries carry those characters still parsing with every row retained.
- **Task 007.** `testRestartIsNotBlockedByAStoppedLaunchesControlOperation` starts a profile, stops it while its control operation is still in flight, and restarts immediately. The fake SSH fixture gained `RELAYBAR_FAKE_SSH_IGNORE_TERM_SPEC`, a forward that ignores `SIGTERM`, so the stopped launch's operation is guaranteed to outlive the restart.

  This test was confirmed to be a regression test, not a tautology: with the per-operation guard temporarily reverted to the previous per-profile guard, it fails with `Restart failed: Another SSH control operation is still running. Automatic retry stopped after 1 attempts.` — the exact defect Task 007 describes.
- **Task 009.** `testGroupingCacheInvalidatesOnEveryMutationPath` covers add, update, move, rename, ungroup, and delete, because the change introduces a cache whose only real risk is staleness.
- **Task 011.** `ProgressPollingIntervalTests` covers the fixed single-file interval, the 1-second directory floor, growth with entry count, and the 8-second bound.
- **Task 012.** `SyntaxHighlightCacheKeyTests` covers key stability, distinctness across appearance, language, and code, length independence between a 9-byte and a 40 KB block, and unambiguous field separation.

### Coverage carried by existing tests

- **Task 006** and **Task 016** are exercised by the existing control-forward suite, including the failure and timeout paths, which assert the output and error text a control operation returns.
- **Task 015** is exercised by `testNormalizesActionableConnectionErrors`. Its host-key expectation was updated for the apostrophe correction that task specifies; every other mapping is unchanged.
- **Task 018** is proved by the build: the removed accessors have no remaining caller. Test references to `browserURL` were redirected to `unambiguousBrowserURL`, the property the app actually calls, and the `forwardArguments` assertion now composes `rules.flatMap(\.sshArguments)` directly.
- **Tasks 010, 014, 017, and 019** preserve observable behavior exactly; the existing suites for argument policy, remote-file rows, master stderr retention, and running counts cover them unchanged.

## Review notes

- Task 009's cache is invalidated from a `didSet` on the saved list, so every mutation path clears it, including in-place subscript assignment. The initial value assigned in `init` does not need invalidation because the cache starts empty.
- Task 007 keeps the single-operation-at-a-time rule; it is now scoped to a launch generation rather than a profile. Continuations still resume exactly once on completion, stop, cancellation, timeout, and launch failure, because a superseded operation stays registered until its own termination handler runs.
- Task 006's handler detachment happens before the synchronous drain, and the operation is removed from the registry first, so a handler block still in flight becomes inert instead of recreating a buffer. Control output stays on the main queue rather than hopping through a `Task`, which preserves FIFO ordering with the termination handler's dispatch.
- Reviewing that rewrite surfaced a pre-existing latent hang on the same path: the drain also ran when `Process.run()` itself threw. No child ever held those pipes' write ends in that case, so `readDataToEndOfFile` would wait on the main queue for an end of file that cannot arrive. The drain is now skipped when the launch failed, where there is nothing to read anyway.
- Task 013 removed cancellation checks from six leaf scanners only. The per-character checks in `stripCommentSegments` and `transformInline` were deliberately kept: one line may be the whole document, so removing them would trade a real cancellation-latency regression for a small constant.
- Task 014 replaced a filesystem probe in a menu builder with a shape test. Reveal now falls back to the enclosing folder when the socket is gone, which is a small behavior change in the stale case and is recorded in the tunnel-management spec.
- No dependency, asset, entitlement, or persisted format changed. No user-visible string changed except Task 005's new refusal message and Task 015's apostrophe correction.

## Deferred work

Task 005 ships the refusal, not the escaping that would make these paths work, and says so in its delivery boundary. Escaping changes the bytes reaching a third-party globber, and the interaction between the sftp tokenizer's backslash handling and `glob(3)` cannot be accepted on unit tests alone. [Task 020](../task-specs/020-escape-glob-metacharacter-paths.md) carries that work and requires a live SSH server holding paths named with `*`, `?`, and `[`.

A live SSH run was not otherwise required. The complete fake-process lifecycle suite and the forwarding suite passed; the opt-in live tests remained skipped.

No release, notarization, publication, or deployment was performed.
