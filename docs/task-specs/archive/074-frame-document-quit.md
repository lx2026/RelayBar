# Task 074 — Quit Frame with an unresponsive document preview

Status: Complete

## Outcome

Frame can quit or switch files when WebKit stops answering a document preview.

## Delivery Boundary

Document navigation, scroll restoration and code-block copying in Frame.

## Work

Remove the dependency on a WebKit reply before the first document load. Make optional scroll reads cancellable and bounded, and discard late replies after switching or closing a preview.

## Acceptance

- The sandboxed app exits when quitting with the library that hung in build 22. Closing and reopening a library window also permits a normal Quit.
- A stalled page cannot prevent selecting another file or finishing renderer shutdown. Responsive pages still retain scroll history and copy the requested code block.
- Existing Frame tests and the native app checks pass.

## Verification

On macOS 27.2.1, build 22 exited with an empty library and hung with the saved two-note library. The trace stopped at the first scroll-position request, before loading the document. Quit then waited for the renderer to finish. The fixed development executable exited with that same library and sandbox.

A real WebKit regression test held a JavaScript alert open. The old renderer failed both the file-switch and shutdown assertions. The fixed renderer passed both and kept the original file selected when the user immediately reselected it. A separate test restored a 500-point scroll offset after navigating back. The existing code-copy tests also passed.

In a signed test copy, the second note rendered, closing the library left zero visible windows, and reopening from Finder restored the same note. ⌘Q ended the process. After relaunch, menu Quit from Settings also ended the process.

The optimized build 23 executable completed four more launch-and-quit cycles in a disposable signed app with the saved library. All four exits were confirmed within 0.26 seconds of the quit request. The local Apple silicon app passed strict signature verification. The warnings-as-errors build and `git diff --check` passed. `./scripts/test.sh frame` passed 17 script tests and reported 238 Frame tests, 3 skipped and zero failures.
