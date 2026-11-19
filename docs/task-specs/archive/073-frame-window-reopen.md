# Task 073 — Reopen the Frame library window

Status: Complete

## Outcome

Opening Frame again after closing its library window returns the user to the selected file in the running app.

## Delivery Boundary

Frame's main window and File → Open. The build 21 reproduction is in the [QA record](../../verification/frame-2.0.0-build-21-qa.md).

## Work

Route the macOS reopen event to the existing SwiftUI library scene and present the folder chooser in that scene.

## Acceptance

- Closing the library with the red button or ⌘W and reopening the app restores the selected file in the same process, including when Settings remains open.
- Reopening a minimized library restores it. Repeated reopen requests keep a single library window, and ordinary activation preserves the front window when the library is already visible.
- File → Open with the library closed presents its folder chooser. The native regression checks and Frame test suite pass.

## Verification

On 2026-11-18, a separately bundled, sandboxed development build on macOS 27.2.1 opened the second of two fixture notes. After the red close button, WindowServer counted zero visible windows for PID 90065. Opening the bundle twice from Finder returned the same note and one visible library window in that PID.

With Settings open, ⌘W followed by a Finder reopen returned the same note ahead of Settings. Reopening also restored the minimized library. When both windows were already visible and Settings was in front, it kept focus. With only Settings visible, ⌘O brought back the library and displayed its folder chooser. The Dock accessibility request timed out, so Finder supplied the native reopen events for this run.

`./scripts/test.sh frame` passed all 17 script tests and reported 236 Frame tests, 3 skipped and zero failures. The new regression test exercises the app delegate with the main window closed, an auxiliary window visible and the main window already visible. The warnings-as-errors Frame build and `git diff --check` passed.

The local Apple silicon build is numbered 22 and passed strict code-signature verification. The isolated development copy and the build 21 executable both stayed running after Quit with the same test library. [Task 074](074-frame-document-quit.md) records the cause, fix and retest.
