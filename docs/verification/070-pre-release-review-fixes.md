# Task 070 — Pre-release review fixes

Date: 2026-11-17. Implemented and pushed on the 2.0.0 pull request; not merged or released. Every check below comes from unit tests and builds; nothing here was exercised in the running apps or against a live SSH host.

## Source of the findings

An independent read-only review of the pull request's whole diff reported three defects it would not ship a public beta with and eight lesser ones. It read the source and ran nothing. Each finding was then confirmed by a regression test written before the fix; all eleven were real. Separately, the pull request's first CI runs, on macOS 15 with an older Xcode than the development Mac, found four further problems.

## Findings from the review

| # | Severity | Defect | Fix | Regression tests |
|---|---|---|---|---|
| 1 | Blocker | RelayBar's HTML preview and its fetches for Frame took the local file name from the remote reply, then removed that file's parent folder: a faulty or hostile host could write outside the temporary folder and have a folder deleted. | The local name is the requested path's own last component, checked to be a single path component; cleanup removes exactly the folder RelayBar created. | `RemoteReplyContainmentTests` (three tests) |
| 2 | Blocker | Frame reused one address for every library in its document view, and pointed it at the next library before the next page had loaded: the page still on show could read the next library's files. | Each library has its own custom-scheme host; a request is served only from the library whose host it names. | `DocumentPreviewTests.testAPageStillOnShowCannotReadTheNextLibrarysFiles` |
| 3 | Blocker | A grouped export planned as "create" replaced a file that appeared at the destination during the copy. | The plan's decision reaches the exporter; a create publishes with an exclusive rename, then a hard link, then an exclusive create, and reports a collision. Single-file Export Exact Copy follows the same rule. | `AssetTests` (three tests) |
| 4 | Should fix | Remote Restore trusted a fresh fingerprint of whatever sat in the archive. | Every stored member is compared with its recorded identity before any move; a mismatch moves nothing and keeps the record. | `FrameRemoteHelperTests.testRestoreRefusesAReplacedArchivedFileAndKeepsItsRecord` |
| 5 | Should fix | One damaged archive record failed the whole Archive listing, and Restore could create such a record. | Records are read one by one and a damaged one is skipped; Restore refuses up front when a record folder holds an unexpected file; a restore whose files are back counts as restored when only record cleanup fails. | `FrameRemoteHelperTests` (three tests) |
| 6 | Should fix | The bridge channel could shut down or write to a descriptor number after closing it. | One owner closes each connection, after its queued writes, and clears the stored number under the lock; the server shuts a connection down only while it is registered. | `BridgeLifecycleTests` (two tests); none was practical for the server-side race |
| 7 | Should fix | A remote reply repeating a path crashed Frame. | Repeated paths are refused at the reply boundary; the same check now covers archive listings. | `RemoteTests.testRepeatedOrUnrequestedEntriesInRepliesAreRejected` |
| 8 | Should fix | The appcast script could sign an archive that was never stapled, and replaced the feed before verifying it. | The archive is extracted and must pass the signature, stapled-ticket, Gatekeeper and identity checks before anything is signed; the feed is built and verified in a temporary folder and copied only on success. | `scripts/tests/test_update_appcast.py` (five tests) |
| 9 | Should fix | Files Frame fetched through RelayBar were held to RelayBar's own 2 MiB Markdown and JSON preview limits. | A bridge fetch is bounded only by the bridge's limit; RelayBar's previews keep theirs. | `RemoteReplyContainmentTests.testFrameFetchOfAnOriginalIsBoundedOnlyByTheBridgeLimit` |
| 10 | Minor | A permanently deleted remote file kept its opened-time record for ever. | Only Archive holds the record; a confirmed Delete drops it. | `ReviewAidsTests.testPermanentRemoteDeleteDropsTheOpenedTimeAndArchiveKeepsIt` |
| 11 | Minor | An empty remote folder first listed by expanding the tree got no change baseline. | An empty listing is told apart from one never loaded, and records the same baseline as opening the folder. | `ReviewAidsTests.testAnEmptyRemoteFolderListedByExpandingGetsTheSameBaselineAsOpeningIt` |

## Findings from CI

- **Standard colours on macOS 13 to 15.** Recorded in [Task 069](069-shared-paper-palette.md#after-the-first-ci-run).
- **RelayBar did not compile with the older Xcode.** A free function that builds a switch now runs on the main actor. The service probe's refusal of authentication challenges used a completion-handler callback whose signature differs between SDK versions, so with the older SDK it would never have been called; it now uses the async form, which is the same in both.
- **Popover scrolling tests.** They compared control frames with the insets; on macOS 13 to 15 a pop-up button's frame is wider than its alignment rectangle. They now compare alignment rectangles.
- **An unreliable bridge test.** `testPeersThatHangUpAtOnceCannotRaiseSIGPIPEAndTheServerKeepsAnswering` opened fifty connections at once against a listen backlog of eight, so macOS sometimes refused one. It now retries a refused connection and passed 100 of 100 runs.

## Left as it is

- Archive records written before identities were recorded still restore without the identity check.
- A damaged archive record is skipped without being reported, because the reply has no field for warnings.
- Opened-time records left held by earlier builds' permanent deletes are not cleaned up.
- The server side of the bridge descriptor fix has no deterministic test.

## Checks

`scripts/test.sh` passes locally with everything in place: 14 script tests; shared package 105 tests (3 skipped); RelayBar 461 tests (33 skipped); Frame 227 tests (3 skipped); no failures. Frame's product build with warnings as errors and `git diff --check` pass. All windows made by tests stay off screen.

## Still to check

- A second independent review of these fixes.
- The fixes in the running apps and against a live SSH host: HTML preview of a remote file, switching libraries while an HTML page is on show, export into a folder that changes during the copy, remote Archive and Restore.
