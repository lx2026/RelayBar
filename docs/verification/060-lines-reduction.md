# Task 060 verification

Status: Implemented — 2026-11-14. Every cut is in, the automated gate passes and each lane's diff was read by a reviewer that did not write it. No signed build or running-app pass was made for this task.

## Baseline

- Branch `codex/task-058-composition` at `5ebcfdd`, identical to `origin/main`, no upstream. The work of Tasks 058 and 059 is uncommitted and is this task's starting point.
- Snapshot of that tree: `.build/task-059-baseline/checkpoint-before-060.tar.gz`.
- Lines before, counted with `find <dir> -name '*.swift' | xargs cat | wc -l`: production 31,431 (RelayBar 20,236, Frame 9,455, shared 1,740); tests 19,950 (RelayBar 13,728, Frame 4,897, shared 1,325).
- Test cases before: 55 shared, 386 RelayBar (27 optional skips), 164 Frame.

## How the cuts were chosen

Four read-only analyses (RelayBar Remote Files and views; RelayBar process, SSH and bridge code; Frame and the kernel; the test suites) each had to cite the code and show the arithmetic. They agreed that little duplication or dead code was left after Task 059. The cuts taken, and the ones rejected or left for the owner, are listed in the task spec.

## Result

| Work item | Production | Tests |
| --- | --- | --- |
| RelayBar: tunnels and Remote Files (eight cuts) | 20,236 → 19,800 (−436) | +15 (two tests rewritten against the registry, all assertions kept) |
| Frame: dead code, `perform`, playback, file-operation prologue | 9,455 → 9,305 (−150) | −20 (one keyed gate for three) |
| RelayBar test fixtures | 0 | −296 |
| Kernel | unchanged | unchanged |
| **Total** | **−586** | **−301** |

Review then added 29 test lines (one case for the standalone preview owner's shutdown), so tests net −272 for this task.

Test cases per class are the same before and after in every file the fixture work touched (`PluginTests` 21 at that point, `TunnelStoreIntegrationTests` 35, `RemoteFilesModelTests` 57, `SFTPRemoteFileServiceTests` 43, `RemoteMarkdownTests` 38, the other 15 classes of `RemoteFilesTests.swift` 56 in total), as are the counts of assertions, `XCTFail`, `XCTUnwrap` and `XCTSkip`.

## Independent review

Each lane's diff was read by a second reviewer against the tree before the change.

- **Frame.** Three differences from strict equivalence were reported. Two were reverted: the remote archive listing runs through the feature's work scope again, so Cancel on a file operation still stops a listing in progress; and `MediaRemoteAccess` is inline again rather than an owned run on every media read. Two were kept and are recorded here: a feature that now uses `FeatureContext.perform` checks that it is still active after its owned run returns rather than inside it, so a result that completes just as the feature is withdrawn is rejected, which is the kernel's stated rule; and the remote file operation's four status fields are set in a different order within one main-actor turn, with no observer between them.
- **RelayBar.** No behaviour difference was found in keyboard handling, deletion, window close and quit, the request tokens, preview classification or the preview getter. One gap was found and closed: the rewritten preview test no longer exercised the standalone owner's `stop()`; `testStoppingAllFormatsClosesEveryPreviewAndRemovesItsFiles` now does.
- **RelayBar test fixtures.** No findings. The reviewer expanded each helper and compared tunnel fields, environment keys, timeouts, delays, predicates and cleanup order for the 25 defaults conversions, the six SFTP conversions, the 33 model conversions and the 39 browser openings, and counted 245 test methods before and after across the 20 classes in the two files, with identical names.

## Gate

- `scripts/test.sh`, warnings as errors, exit 0 (`.build/task-060-062-final.log`): 2 release-plan tests, 68 shared (1 optional skip), 414 RelayBar (28 optional skips), 185 Frame (1 optional skip), zero failures. These totals include the tests added by Tasks 061 and 062. The log's `CoreData: error` lines come from a system service during the RelayBar suite and are identical in number to Task 059's final log.
- `swift build --package-path Apps/Frame --product Frame -Xswiftc -warnings-as-errors`: complete.
- `xcodebuild -project Apps/RelayBar/RelayBar.xcodeproj -scheme RelayBar -configuration Debug CODE_SIGNING_ALLOWED=NO build`: succeeded.
- `git diff --check`: clean. `Apps/` and `Packages/` are untracked, so each lane also checked its files for trailing whitespace.

## Opt-in visual harness

`VisualSnapshotHarness` (RelayBar, `RELAYBAR_SNAPSHOT_DIR`) is skipped by the gate, so it was run separately because this task changed the Remote Files views.

- On the current tree, ten of its eleven tests pass when run together (209 seconds), and `testCaptureTask042To044RemoteFileSnapshots` passes when run alone (24 seconds, ten snapshots).
- Run as a whole class, the harness stalls in SwiftUI layout when it reaches `testCaptureTask042To044RemoteFileSnapshots` after the other tests, having written 68 snapshots. The tree from before this task (`checkpoint-before-060`) stalls at the same test with the same 68 snapshots, and passes the same test alone in the same 24 seconds. The stall is therefore not caused by this task. It was not investigated further and is not fixed.

## Not verified

- No signed build, native UI pass or live SSH host. The keyboard monitors in the Remote Files window have no unit tests; their manual check (Return and Enter in the sidebar; Return, Space, Command-Down and Command-Backspace in the list; arrows and Command-Backspace in preview; keys passing through to a web view or the JSON text view) was not run.
- Closing the Remote Files window during an upload, and quitting with it open, were not tried in a running app.

## Left for the owner

- RelayBar's native Markdown stack (about 3,700 lines and three dependencies) against Frame's WebKit renderer (about 500): the largest available cut, and a change to RelayBar's documented Obsidian reading compatibility.
- Narrowing Frame's shell handle `ComposedRemoteAccess` to library and file reading (13 lines; tightens what the UI can reach; rewrites three tests).
- API only tests use in Frame (`rememberOpen` on the library protocol, `folderChoices`, the selection byte and member counts, `toggleRemoteFolder`, `RemoteFolderIndex.rows`): about 38 lines, each with test cases that would go with it.
