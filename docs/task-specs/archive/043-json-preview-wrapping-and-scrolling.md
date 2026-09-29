# Task 043 — JSON Preview Wrapping and Scrolling

Status: Complete

Created: 2026-08-30

Completed: 2026-08-30

Follows: Task 040

## Outcome

Long JSON content wraps to the available preview width and the complete
formatted document remains vertically scrollable at every supported window and
text size.

## Delivery Boundary

### Included

- Reliable soft wrapping for long keys, strings, numbers, arrays, and scalar
  top-level values in the native read-only JSON text view.
- A visible, functional vertical scroller with trackpad, mouse-wheel, keyboard,
  VoiceOver, resize, and larger-text behavior.
- Preservation of selection, copy, syntax coloring, formatting, security
  limits, and preview lifecycle behavior from Task 040.

### Excluded

- JSON editing, folding, a tree view, search, schema features, line numbers, or
  horizontal scrolling while wrapping is enabled.
- Changes to JSON parsing, size or encoding limits, remote fetching, download,
  or persistence.

## Work

- Correct the `NSTextView`, text-container, clip-view, and `NSScrollView`
  sizing relationship so the text container tracks the visible width, expands
  vertically, and reports a scrollable document height.
- Keep the vertical scroller enabled and the horizontal scroller disabled.
  Preserve insets, selectable read-only text, adaptive colors, and native focus.
- Add regression coverage using deeply nested content and a very long unbroken
  string at normal, narrow, resized, and larger-text layouts. Verify both
  pointer and keyboard scrolling reach the final line.

## Acceptance

- No formatted JSON token is clipped beyond the right edge at supported widths;
  long content wraps and reflows after live resize.
- The preview scrolls from the first through the final line without changing
  selection, syntax attributes, or content.
- Aqua, Dark Aqua, narrow-window, larger-text, keyboard, and accessibility
  evidence pass with no regression to Task 040's bounds or lifecycle.
