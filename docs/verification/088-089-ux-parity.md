# Tasks 088 and 089: shared behaviour across RelayBar, Frame and mobile

Date: 2026-11-19. Covers [Task 088](../task-specs/archive/088-shared-preview-policy.md), [Task 089](../task-specs/archive/089-shared-browsing-details-and-errors.md) and the test hardening that followed them.

## Result

`./scripts/test.sh parity` reports 4 definitions outside the shared package (60 before Task 088), 26 of 26 shared fixture cases run by both the Mac and the mobile tests, and no ledger rows left to fix (18 before).

## Automated checks on the final tree

| Suite | Switches on | Result |
|---|---|---|
| RelayBar | Pillow helper Python, off-screen snapshots, live host listing, live helper, live tunnel | 471 tests, 0 failures, 13 skipped |
| RelayBar real-SSH loopback (`scripts/verify-live-loopback.py`) | private loopback server | 5 tests, 0 failures |
| Frame | off-screen snapshots | 243 tests, 0 failures, none skipped |
| Shared package | none | 94 tests, 0 failures, 2 skipped |
| SSH transport | run one test at a time | 46 tests, 0 failures; 30 consecutive runs clean |
| Mobile | none | 58 tests, 0 failures; 11 web-view checks pass |

The 13 RelayBar skips are the five loopback tests (run separately above), five benchmarks, one key-window test that needs the screen, the Unix-socket live test and the disposable-fixture transfer test. Warnings are errors in every suite. `git diff --check` is clean.

Live checks ran read-only against a host on the tailnet: listing its home folder through SFTP, running the embedded remote helper's `list` action with the host's own Python, and opening one local forward.

## Visual evidence

Sixteen off-screen renders, light and dark, written only when the snapshot directories are set:

- Frame main window: `frame-folder` (pin glyphs, hidden-items row in the sidebar and the file area), `frame-folder-shown`, `frame-details` (prompt from a compressed PNG text chunk, negative prompt, seed and steps in the shared order).
- RelayBar Remote Files: `remote-folder` (folders first, newest first, hidden-items row), `remote-folder-shown`, `remote-markdown-paper`, `remote-refused`, `remote-changed-key` (title and recovery line).

The mobile gallery was regenerated; the iPad image reader shows one position for the bar and the subtitle.

## Defects found by this testing, and fixed

- RelayBar read a listing's time as this Mac's local time and moved anything more than an hour ahead to the previous year, so a file just changed on a server in a later time zone sorted as a year old. The allowance is now 26 hours, with a test.
- The localhost gate, asked for any free port, took a number from IPv4 and failed when another socket held that number on IPv6 alone. It now tries further numbers. The app asks for fixed ports, so this reached the web-view checker and the tests, not ordinary use. A test reproduces it by holding the next numbers on IPv6.
- The transport tests bind chosen port numbers while sharing one loopback port space, and ran in parallel. With the reproducing test in place 24 of 60 parallel runs failed; run one at a time, 30 of 30 pass. `scripts/test.sh` now runs that suite serially. Two of those tests name the sockets holding a port if it is ever found taken.
- Two mobile file-search tests assumed a listing order that no longer holds now that four folders are listed at a time; they compare sorted lists.
- The iPad image reader showed two different positions for one image; both follow the folder's shown order.

## Not explained

One mobile test, `selectedSearchHitOpensAndHostOverrideRemovesIndex`, timed out once at its three-second wait. It did not recur in about 475 further runs, alone, with the loopback tests, and under background CPU load. The test now reports the index's state (stopped, walking, foreground traffic, pending folders, last failure) if it stalls again.

## Local installation

Release bundles built from this tree: RelayBar 2.0.0 (29), universal, and Frame 2.0.0 (26), Apple silicon, both Developer ID signed with strict verification passing, not notarized and not published. Both replaced the installed apps after the previous bundles were copied aside. RelayBar was relaunched in the background and stayed up; Frame was started hidden, stayed up, and was quit. No crash report was written. The mobile app was installed on an iPad Pro.

## Open for a hand check

Pointer and keyboard behaviour of the new rows on the Macs, VoiceOver, real full screen, and touch behaviour on the iPad were not exercised; nothing that takes over the screen was run.
