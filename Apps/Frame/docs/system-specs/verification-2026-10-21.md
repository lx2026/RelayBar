# Frame 0.2.0 delivery verification

Date: 2026-10-21 · local macOS 27.0.1, arm64 · build 2

## Automated checks

Final `swift test`: **30 passed, 0 failures** at 23:14 local time.

- Seven original tests: PNG/AI metadata, recursive queries, exact destination replacement, same-source rejection, and synthetic performance budgets.
- Twelve redesign tests: mixed extensions, real H.264/AAC MP4/MOV/M4V metadata/posters, rotated and very short clips, corrupt video completion, paused playback and release lifecycle, scope/favorite identity, recents cap, unavailable roots, stale scans, Undo collisions, async video export, file aliases, and Light/Dark contrast.
- Eleven selection tests: independent preview/targets, 10,000-ID selection, anchored range reset/clamping, scope changes without armed Trash, Inspect batch preservation, cancellation, partial failures, changed sources, grouped restore, and missing/replaced/occupied Trash entries.

Final synthetic timings: 5,000-file scan **0.220 s**; filter **0.00387 s**; stage plus twelve thumbnails **0.00373 s**; cached adjacent image **0.0000176 s**. These are small generated local fixtures, not representative timings for every real library. The 10,000-ID selection test completed in 0.006 s and performs no media decode.

All tested normal text/surface and filled-button pairs meet 4.5:1 in both appearances. Test file mutations used generated temporary fixtures; user media was not deleted or exported for testing.

## Native checks

- Live Light/Dark changes without relaunch; minimum 960 × 640 content window; identical image geometry/colors and adjacent metadata.
- Native plain/Command/Shift selection, repeated Shift-arrow extension, Select All/clear, visible target count, “Not selected,” and disabled empty-selection actions.
- Return enters Inspect, a second Return enters Focus, Escape leaves one layer at a time. The three-file selection survived returning to Contact Sheet.
- Folder outline scope changes reset batch targets; toolbar recents display names plus parent locations. Existing catalog roots survived rebuilding and installation.
- Rotated MOV displayed 90 × 160 with H.264/AAC metadata. Native playback advanced to its final frame. Timeline seeking on MP4 visibly reached 00:00:00.500. Static Browse posters never started playback.
- Installed release launched from `/Applications/Frame.app`, restored its root bookmark, and passed the same range-selection smoke check. The debug-only Verification menu is absent. The user’s previously open folder was restored afterward with zero destructive targets selected.

## Native screenshots

| Surface | Light | Dark |
| --- | --- | --- |
| Contact Sheet with three selected files | [Light](assets/2026-10-21/contact-light.jpg) | [Installed release](assets/2026-10-21/contact-dark.jpg) |
| Same image in Inspect | [Light](assets/2026-10-21/image-light.jpg) | [Dark](assets/2026-10-21/image-dark.jpg) |
| Same rotated video in Inspect | [Light](assets/2026-10-21/video-light.jpg) | [Dark](assets/2026-10-21/video-dark.jpg) |

Light/Dark comparisons used a debug-only NSApp appearance override, not a change to the user’s system preference. The released app follows the system. Video screenshots show different playback positions. All saved screenshots use synthetic project fixtures, not user photos.

## Build and installation

`Scripts/build-app.sh release` succeeded. Strict deep code-signature verification, plist lint, embedded entitlements, arm64 architecture, and exact icon-resource comparison passed. The existing sandbox/bookmark/user-selected-file entitlements and bundle ID `com.lx2026.Frame` are unchanged. No catalog migration or preferences reset was performed.

- Installed: `/Applications/Frame.app`, version **0.2.0**, build **2**.
- Executable SHA-256: `8e6dc589edcafe6447befa9bac284241617a6e3b7e43636d4ee5ec339792f468`.
- Recoverable previous app: `.build/backups/Frame-0.1.0-build1-2026-10-21.app` in this repository.
- Previous executable SHA-256: `f56bbd8e1bac350a3027114837a0bd111b1ee8d486f35537ec06b89a9ca5abf8`.

The new bundle was staged and verified before moving the previous bundle to its backup and renaming the new bundle into Applications. Both resulting app signatures passed; installed bytes match the release build. No source Git repository was present, so no commit/tag was created. No release was published and no notarization is claimed.

## Review and remaining manual checks

Three original design rounds were followed by two Contact Sheet design rounds and an explicitly authorized source audit. The audit’s five actionable defects were fixed and covered by targeted tests/native checks; no post-fix review approval is claimed. See the [selection task](../task-specs/2026-10-21-contact-sheet-selection.md) for decisions.

Remaining manual coverage: physical drive removal/reconnection and expired sandbox access; native folder drag/drop; complete VoiceOver traversal; all error/recovery/notice states in both appearances; audible-output listening; older macOS and Intel hardware. Recovery/identity/error handling has automated coverage, but this is not a claim of a complete native screenshot matrix. File-operation tests run in the test process, not a UI-driven deletion of user files.
