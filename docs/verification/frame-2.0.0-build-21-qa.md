# Frame 2.0.0 build 21 release QA

**Post-release QA on 2026-11-18.** The published Beta 2 can remain active with no main window after a reopen request. **Window → Frame** recovered the selected document in the run with Settings open. The subsequent development fix and its native retest are recorded in [Task 073](../task-specs/archive/073-frame-window-reopen.md). The reported permanent Icons freeze remains open.

## Candidate

Frame Beta 2, commit `9e84e991958b8912bfa50c7c6fee884442e952a3`. Tested a fresh extraction of `.build/Frame.zip` on a MacBookPro18,1 with 16 GiB RAM and macOS 27.2.1 (26B131). ZIP SHA-256 was `02d1871a7e2d83ecb29ce1bd1e2acf862253eb9509e95ee339b65949fb161818`. Both arm64 and x86_64 slices were present. Strict deep signature verification, Gatekeeper assessment as Notarized Developer ID, and stapled-ticket validation passed.

## Results

| Check | Result | Observed on this candidate |
| --- | --- | --- |
| Window recovery | **Fail** | Selected the second file and clicked the red close button. After opening the same bundle in Finder, PID 25522 was still running, active and unhidden. WindowServer counted zero on-screen layer-zero windows for that PID. With Settings open, closing the main window with ⌘W and reopening from Finder brought Settings forward. **Window → Frame** then restored the selected second file. The Dock automation timed out before a Dock click could be verified. |
| Large notes folder | Passed on local fixtures | Opened 10,000 small Markdown/HTML files in one directory, then another 10,000 split across the root and 99 subfolders. Each fixture completed five Files → Icons → scroll → select → Files cycles and returned the selected note. Subfolders was on. In a separate warm run, a direct click on the second tile returned in **1.56 s flat** and **1.26 s nested**, measured from clicking Icons, including automation overhead. Selection changed to the second note in both cases. The original library was not exercised. |
| Launch and upgrade | Partial | Saved a favorite, folder and 190-point thumbnail preference using installed build 20. Quit and launched build 21 from the extracted package in the same account. It reopened the folder, showed the image as a favorite and retained 190 points. A fresh macOS login and a packaged run with RelayBar quit remain untested. |
| Browse and read | Pass | Markdown and HTML switched between Rendered and Source. The image showed its dimensions and sidecar, and the movie timeline advanced. An unknown binary file showed “No preview” and “Open in Default App.” Search narrowed the library and Backspace edited the query. The Images filter showed one of seven items. The sidebar returned after leaving full screen with Control-Command-F. |
| Local file actions | Pass | Used the packaged UI to export a PNG and its JSON sidecar, archive the filtered selection, restore it, move it to Trash and undo. Both exported and archived files matched their original SHA-256 hashes. Trash removed only the two group members. After Undo all seven original files matched their hashes. |
| Remote recovery | Partial | Frame's automated session reconnect and document reload checks passed. Four additional file-operation tests passed over real SSH/SFTP to a disposable localhost server, including interrupted transfer and preservation of unrelated files. The packaged RelayBar → Frame handoff with an interrupted preview and reconnect remains unverified. |

## Test evidence

- `./scripts/test.sh all` passed on arm64. The release-script suite passed all 17 tests. The Swift suites reported 24 Markdown tests (2 skipped), 83 composition tests (1 skipped), 465 RelayBar tests (33 skipped) and 235 Frame tests (3 skipped), with zero failures.
- The x86_64 Frame XCTest bundle also ran under Rosetta on the same Mac. It reported 235 tests, 3 skipped and zero failures. The first invocation additionally launched an arm64 Swift Testing helper, which failed to load the Intel-only test bundle after XCTest passed. Frame uses XCTest throughout. Rerunning with `--enable-xctest --disable-swift-testing` exited successfully.
- For the separate live SSH run, an existing tunnel owned port 8765. A temporary copy of the repository's loopback runner used 18765 for its HTTP helper and selected the four file-operation tests. The forwarding test that requires 8765 was excluded. The runner removed its server, keys and fixture at exit.
- The QA favorite and three temporary library shortcuts were removed from Frame, the thumbnail preference was restored to 160 points, and Frame was returned to its original unavailable-library view before quitting. The installed bundles and active RelayBar session were retained.
- At the end of the build 21 run, the window-reopen retest, investigation of the reported library freeze, and fresh-login, paired-app, macOS 14 and physical Intel checks were outstanding.
