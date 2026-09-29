# JSON Preview

JSON preview is a bounded, native, read-only state inside the Remote Files
preview workspace.

## Entry and lifecycle

- A regular file ending in `.json`, case-insensitively, is previewable from a
  folder listing, sibling list, or direct absolute path.
- Preview uses the active server snapshot and the owned SSH master to download
  into a private `0700` temporary directory. The service rejects a known size
  above 2 MiB before transfer and aborts a transfer that crosses that limit.
- The decoder independently enforces the 2 MiB limit, accepts UTF-8 with an
  optional BOM, and rejects NULs and invalid UTF-8.
- Parsing and formatting run in detached work. A preview generation prevents a
  cancelled or superseded result from publishing, and leaving preview, changing
  location, closing the window, or quitting removes the temporary directory.
- Error states distinguish oversized, invalidly encoded, and malformed JSON
  while retaining Back, retry, and Download of the original bytes.

## Rendering

- Every valid JSON top-level value is supported: object, array, string, number,
  Boolean, and null.
- `JSONSerialization` validates the document and emits stable indented output;
  formatting changes whitespace and key order only, not represented values.
- The document appears in a native `NSTextView` inside an `NSScrollView`. Text
  is read-only, selectable, monospaced, and findable. Its text container tracks
  the visible width after resize, soft-wraps long unbroken tokens without a
  horizontal scroller, grows to the complete laid-out height, and remains
  vertically scrollable from the first through final line.
- Dynamic macOS label and system colors distinguish object keys, string values,
  numbers, literals, and punctuation in Aqua and Dark Aqua. Color is not used
  to convey validity or operational state.

## Active-content boundary

- JSON is treated only as data. RelayBar does not use a web view, execute
  strings, resolve references, fetch URLs or file paths, validate a schema,
  edit the document, or write remote content.
- The formatted text and syntax attributes are session-only. RelayBar does not
  index, log, or persist preview content.

See [Remote Files](remote-files.md) and
[Security boundaries](../shared/security-boundaries.md).
