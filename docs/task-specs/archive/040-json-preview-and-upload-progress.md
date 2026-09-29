# Task 040 — JSON Preview and Upload Percentage Progress

Status: Complete

Created: 2026-08-29

Follows: Task 037

## Outcome

Remote Files renders supported JSON files in its existing read-only preview
workspace and shows determinate percentage progress while upload bytes are being
staged. The UI continues to distinguish byte transfer from publication and
cleanup so 100% staged never implies that the final remote file is already
published.

## Delivery Boundary

### Included

- Native, selectable preview of regular `.json` files opened from a folder or
  direct absolute path, including preview-sibling navigation.
- Bounded local JSON decoding, validation, formatting, and adaptive syntax
  presentation using the existing private preview lifecycle.
- Monotonic upload byte and percentage progress during the staging phase, with
  the existing publishing, cleanup, cancellation, retry, and completion states.
- Automated, visual, and accessibility verification plus updates to the
  affected system specifications. Live-SSH coverage remains release-hardening
  evidence when an isolated writable target is configured.

### Excluded

- JSON editing, JSON5, comments, schema validation, tree manipulation, folding,
  search, remote references, or remote writes beyond the existing upload flow.
- Upload speed or time estimates, resumption, background queues, multi-file or
  folder upload, and changes to the staged publication or replacement contract.
- Commit, push, release, notarization, publication, or deployment.

## Work

### 1. Add bounded JSON preview

- Treat a regular file whose extension is `.json`, case-insensitively, as a
  previewable sibling alongside supported images and Markdown. Direct JSON
  paths use the same single-file browser and Back behavior as other previews.
- Download preview content through the existing app-owned SSH session into a
  private temporary directory. Apply a 2 MiB transfer and decoder limit, accept
  UTF-8 with an optional byte-order mark, reject NULs and invalid JSON, and
  clean temporary content on cancellation, navigation, replacement, window
  close, and application termination.
- Parse and format away from the main actor. Render every valid top-level JSON
  value in a native, read-only, selectable monospaced view with adaptive syntax
  colors and horizontal and vertical overflow. Formatting may change
  whitespace but must not change the represented JSON value; Download retains
  the original bytes.
- Keep parsing and presentation generation-guarded so a canceled or superseded
  JSON preview cannot publish late content. Malformed, unsupported-encoding,
  and oversized files show a specific bounded error while retaining Back,
  retry, and Download.
- Do not use a web view, execute content, resolve references, fetch network or
  local resources named by the document, or add an editing surface.

### 2. Report truthful upload percentage progress

- Extend the upload service and presentation state with completed and total
  byte counts. The local regular-file size is the total; in-flight measurements
  stay below that total, published values never move backward, and completion
  reaches the total only after SFTP confirms that staging succeeded.
- While the app-owned staging upload is active, measure the exact known staging
  file through the existing owned SSH master using bounded SFTP operations.
  Permit at most one measurement at a time and no more than two measurements
  per second. Stop measurement promptly when staging ends, cancellation begins,
  the attempt is superseded, or the session retires.
- Progress measurement never uses a shell, guesses a path, parses SFTP's
  human-oriented terminal progress meter, weakens output or path limits, or
  determines upload success. A failed measurement retains the last confirmed
  byte count and does not fail an otherwise healthy upload.
- Present a determinate progress bar and integer percentage with the filename
  during staging. Announce the percentage through accessibility state without
  relying on color. A zero-byte file becomes fully staged when its staging
  operation succeeds.
- Set staging to 100% only after SFTP confirms all bytes were written. Continue
  to show distinct **Publishing…** and **Removing temporary file…** phases, and
  report completion only after the existing safe publication contract succeeds.
- Scope every measurement and callback to its upload generation so cancellation,
  retry, navigation, connection loss, and window close cannot mutate a newer
  attempt or leave a polling child running.

### 3. Verify the complete behavior

- Add deterministic coverage for JSON classification, direct-path opening,
  valid objects, arrays and scalar values, Unicode, optional BOM, invalid UTF-8,
  NULs, malformed input, size limits, cancellation, temporary cleanup, sibling
  navigation, and stale decoder results.
- Cover upload progress scheduling, byte clamping, monotonicity, zero-byte and
  short uploads, measurement failure, staging completion, publication failure,
  cancellation, retry, master loss, stale callbacks, and shutdown.
- Capture JSON previews and upload states at early, partial, fully staged,
  publishing, failure, and cancellation points in Aqua, Dark Aqua, keyboard
  focus, narrow layout, and larger text.
- When an isolated writable SSH target is configured, exercise a JSON preview
  plus successful, canceled, replacement, and failed uploads as additional
  release-hardening evidence.

## Acceptance

- Opening a valid bounded `.json` file from a listing or direct path presents a
  native, selectable, read-only JSON preview; malformed, invalidly encoded, and
  oversized files fail with specific errors and never publish partial content.
- JSON joins the existing preview-sibling and lifecycle behavior without
  enabling document-controlled execution, fetching, editing, or persistent
  content storage.
- A representative upload presents monotonic byte-based progress from staging
  through 100%, remains visibly in publishing or cleanup afterward when
  applicable, and reports completion only after safe publication succeeds.
- Cancellation, failure, retry, navigation, master loss, and shutdown stop or
  isolate measurement work and preserve the existing staging-cleanup and
  destination-integrity guarantees.
- Relevant automated, visual, and accessibility checks pass;
  `git diff --check` passes; the Remote Files and JSON system specifications
  describe the implemented behavior; and evidence is recorded before this spec
  is completed and archived.

## Completion

Accepted: 2026-08-30

The implemented behavior, automated suite, offscreen visual captures, system
specifications, and installed local review build were accepted. The optional
live-SSH exercise is recorded in the verification report for later release
hardening and does not block this task's completion. The long-line wrapping and
scrolling defect reported after acceptance is tracked by Task 043.
