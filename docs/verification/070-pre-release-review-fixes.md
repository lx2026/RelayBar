# Task 070 — Pre-release review fixes

Date: 2026-11-17. Merged to `main` with the 2.0.0 pull request and first built into RelayBar build 26 and Frame build 20 ([Task 071](071-2.0.0-beta-1-pre-releases.md)). Every check below comes from unit tests and builds; nothing here was exercised in the running apps or against a live SSH host.

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

## Second review

A second read-only review of the fixes found findings 1, 2, 6, 7, 8, 9 and 11 closed and the other four partly closed, and reported nine further points. All nine were confirmed by a failing test and fixed.

| Area | Defect | Fix | Regression tests |
|---|---|---|---|
| Frame, local documents | Paths were split by `Character`. A slash followed by a combining mark is one character, so a separator could hide inside one component and an intermediate symlink could lead outside the selected folder. | Paths are split at every slash byte, each part is checked, and the descriptor walk uses that same list. The shared `validPath` and `validName` checks find slashes the same way. | `DocumentPreviewTests.testLocalResourcesSplitAtEverySlashEvenOneACombiningMarkFollows`, `BridgePathValidationTests` |
| Frame, single-file export | Whatever existed when Frame looked, after the save panel closed, counted as agreed to. | The destination's identity is recorded when the panel returns; only that same file is replaced, anything else is a collision. | `AssetTests.testSingleFileExportReplacesOnlyTheFileThePersonAgreedTo` |
| Frame, export cleanup | A failed publish or a grouped rollback could remove a file another program had written at the same name meanwhile. | Publishing returns the file it published, held by descriptor; cleanup and rollback remove a name only while it is still that file, and otherwise leave it and report the path. | `AssetTests.testFailedExclusiveCopyLeavesAFileThatReplacedIt`, `testGroupedRollbackLeavesAMemberAnotherAppReplacedAfterPublication` |
| Frame, change markers | Deleting an archived group for good left its companions' opened times held. | Archived items carry their original paths, and the records are keyed by them. | `ReviewAidsTests.testAnArchivedGroupsSidecarLosesItsOpenedTimeWhenDeletedForGood` |
| Remote archive | A record folder under a second spelling of its id made the whole listing unreadable. | A folder whose name is not the canonical spelling of its id is skipped. | `FrameRemoteHelperTests.testDamagedArchiveRecordsDoNotHideHealthyOnes` |
| Remote archive | A restored record stayed listed when its manifest could not be removed. | A record whose members are all back at their originals is left out; a partial move stays listed. | `testRestoreSucceedsWhenOnlyRecordCleanupFails`, `testPartlyRestoredRecordStaysListedAndRecoverable` |
| Remote archive | A manifest with a null identity field skipped the identity check. | Only an absent field is exempt; null or malformed moves nothing. | `testRestoreRefusesAReplacedFileWhenIdentitiesAreNullOrMalformed` |
| Appcast script | The archive's publisher and the update key were not checked before signing. | The signature check requires this project's team and bundle identifier, and the archive's feed address and public key and the signing account's key must match the app's own settings, before anything is signed. | `test_update_appcast.py` (two tests) |
| Appcast script | The final copy could leave a truncated feed. | The verified feed is written beside the old one and renamed into place. | `test_update_appcast.py` |

Two limits are stated in the code: a file created between the person's click in the save panel and Frame's look cannot be told apart from one they agreed to replace, and on volumes with neither exclusive rename nor hard links (exFAT, FAT32) a file being exported is briefly visible while incomplete.

## Third review

A narrow third review of the local-document and export changes found the local reader's escape closed, along with the three archive points, the atomic feed publication and the archived companions' records. It reported six further points. Four are fixed:

| Area | Defect | Fix | Regression tests |
|---|---|---|---|
| Frame, grouped export | A planned replace replaced whatever was at the destination after the copy, so a file another program saved during a long copy was lost. | The plan records each confirmed file's identity and publication replaces only that file; anything else is a collision and the rollback restores the members already replaced. | `AssetTests.testPlannedReplaceNeverReplacesAFileSavedDuringTheCopy` |
| Frame, export cleanup | A failed look-up counted as "gone" and failed removals were ignored, so cleanup could report success with a file left behind. | A failed look-up is told apart from an absent file, every removal is checked, and any path left behind is named in the error. | `AssetTests.testCleanupNamesFilesItCouldNotTakeBack`; no seam for the private-name and hard-link removals |
| Frame, remote fetch | A file whose name starts with a combining mark was refused, because the reply's path was split by character. | The reply's path is split at slash bytes like every other checked path. | `RemoteTests.testFileWhoseNameStartsWithACombiningMarkDownloads`, and a `validPath` case only the byte-level check catches |
| Appcast script | The team requirement was passed to `codesign` in a form the tool rejects, so a correctly signed archive would have been refused; the stand-in tool in the tests accepted the same wrong form. | The requirement is passed as its own argument, and the stand-in parses it as the real tool does. Checked read-only against the installed RelayBar: this project's team is accepted, another team refused. | `test_update_appcast.py` |

Two are recorded as known limits, each needing another program to write the same name within an instant of Frame's last step: a different file arriving between Frame's final look at the destination and the replace call in single-file export; and the temporary names Frame uses in the destination folder during rollback, which are ordinary entries another program could replace.

## Left as it is

- Archive records written before identities were recorded still restore without the identity check.
- A damaged archive record is skipped without being reported, because the reply has no field for warnings.
- Opened-time records left held by earlier builds' permanent deletes are not cleaned up.
- The server side of the bridge descriptor fix has no deterministic test.
- An archive record with a null or malformed identity is left out of the listing, so it cannot be restored or deleted through Frame; its files stay in the archive folder on the host.

## Checks

`scripts/test.sh` passes locally with all three rounds in place: 17 script tests; shared package 107 tests (3 skipped); RelayBar 463 tests (33 skipped); Frame 234 tests (3 skipped); no failures. Frame's product build with warnings as errors and `git diff --check` pass. All windows made by tests stay off screen. CI on macOS 15 passed on each of the three rounds.

## Still to check

- The fixes in the running apps and against a live SSH host: HTML preview of a remote file, switching libraries while an HTML page is on show, export into a folder that changes during the copy, remote Archive and Restore.
