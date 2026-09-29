# Task 043 — JSON Preview Wrapping and Scrolling Verification

Verified: 2026-08-30

Result: Complete. Native wrapping and vertical scrolling, automated checks,
system documentation, and Aqua/Dark Aqua visual evidence pass. The final source
bundle is included in the locally installed review application described below.

## Automated evidence

- The complete warnings-as-errors Swift suite passed 312 tests with 19 expected
  opt-in live, benchmark, and snapshot tests skipped and no failures.
- `testNativeTextViewWrapsLongTokensAndProvidesVerticalScrolling` constructs the
  production AppKit view with a long unbroken token and verifies width-tracking
  reflow, a document height larger than the viewport, scroll-to-bottom behavior,
  live-width resize, no horizontal scroller, preserved attributed contents,
  and selectable read-only text.
- Existing Task 040 JSON tests continue to cover deterministic formatting,
  syntax attributes, objects, arrays, scalars, Unicode, malformed data, UTF-8,
  NUL, and the 2 MiB bound.
- The macOS Xcode Debug build passed with the RelayBar target's authoritative
  complete strict-concurrency and warnings-as-errors settings.
- `plutil -lint` passed for the Xcode project and application property list; the
  fake-SFTP fixture passed `sh -n`; and `git diff --check` passed.

## Visual and accessibility evidence

`VisualSnapshotHarness/testCaptureTask042To044RemoteFileSnapshots` passed and
produced inspected Aqua and Dark Aqua captures at normal and larger text sizes.
Very long JSON strings visibly wrap inside the preview instead of clipping or
creating a horizontal-scroll layout, while the document extends beyond the
viewport for native vertical scrolling.

The snapshot harness exposed a recursive AppKit layout failure in an interim
custom scroll-view workaround. That workaround was removed. The completed view
uses the standard `NSScrollView`/`NSTextView` sizing contract, and both the
offscreen matrix and the complete suite pass without the layout recursion.

The final temporary captures are in
`/tmp/relaybar-042-044-complete.kum95L`; they are reproducible verification
output rather than repository assets.

## Security and lifecycle evidence

- Rendering remains a native, non-editable, selectable attributed text view;
  no web view, execution context, reference resolution, or network-capable
  renderer was added.
- Task 040's parsing, byte, encoding, generation, cancellation, and private
  temporary-file boundaries are unchanged.
- Reflow and scrolling do not mutate, persist, or transmit preview contents or
  selection state.

## Local review installation

At the user's explicit request, the Developer-ID-signed arm64 Debug review
build was installed and launched at `/Applications/RelayBar.app`. Deep signature
verification passed, and the installed executable's SHA-256
`cabc7ef244cc8428c72fe2e99e4fb6bd267574007428ccc1b9a3dfd89ae8ee79`
matches the verified source bundle. The previous installed review app and source
bundle are preserved at `.build/RelayBar-040-041-installed.app` and
`.build/RelayBar-040-041-source-build.app`. No release, publication, push, or
remote deployment was performed.
