# Task 040 — JSON Preview and Upload Progress Verification

Verified: 2026-08-30

Result: Complete. Implementation, focused automated checks, system
documentation, offscreen visual evidence, and the installed local review build
pass and were accepted on 2026-08-30.

## Automated evidence

- The warnings-as-errors focused run covering `RemoteJSONPreviewTests`,
  `RemoteUploadPresentationTests`, `SFTPRemoteFileServiceTests`, and
  `RemoteFilesModelTests` passed 95 tests with one expected opt-in live test
  skipped and no failures.
- The complete warnings-as-errors Swift suite passed 297 tests with 18 expected
  opt-in live, benchmark, and snapshot tests skipped and no failures.
- JSON coverage verifies case-insensitive regular-file classification, direct
  and listed preview lifecycle, objects, arrays, scalar values, Unicode,
  optional BOM, deterministic formatting, adaptive syntax attributes, invalid
  UTF-8, NUL, malformed input, the 2 MiB limit, and temporary cleanup.
- Upload coverage verifies exact staging-path measurements, bounded polling,
  intermediate bytes, completion only after `put`, zero-byte completion,
  early-100 suppression, cancellation, publication races, master replacement,
  cleanup, replacement, and existing retry/shutdown isolation.
- Fake SFTP progress holds `put` open while exact-path `ls` measurements report
  a partial byte count. The observed update sequence is 0, partial, fully
  staged, then publishing; measurement commands remain serialized and within
  the twice-per-second bound. Cancellation retains the last measured count
  during cleanup instead of claiming the unconfirmed total.
- The unsigned arm64 Debug Xcode app build passed with complete dependencies.
- `plutil -lint` passed for the Xcode project and application property list;
  the fake-SFTP fixture passed `sh -n`; and `git diff --check` passed.

## Visual and accessibility evidence

`VisualSnapshotHarness/testCaptureTask040And041RemoteFileSnapshots` passed and
produced reproducible Aqua and Dark Aqua captures for native JSON preview and a
50% upload. The inspected 980 × 640 and 920 × 600 point images show:

- selectable monospaced JSON with distinct adaptive key, string, number,
  literal, and punctuation colors, the JSON sibling icon, and Download/Delete
  toolbar actions; the subsequently reported long-line wrapping and scrolling
  defect is tracked separately by Task 043;
- a determinate staging bar labelled `50% · 1 KB of 2 KB`, with navigation,
  refresh, upload, and row mutation controls disabled during the operation;
- adequate contrast in both appearances without relying on color for progress.

The final temporary captures are in
`/tmp/RelayBarTask040041Final.d9rUSJ`; they are reproducible verification
output rather than repository assets. The progress bar's accessibility value
uses the same percentage and byte text displayed visually.

## Security and lifecycle evidence

- JSON uses `JSONSerialization` away from the main actor and a native
  `NSTextView`; there is no web view, content execution, reference resolution,
  schema network access, editing, or persistence.
- Service and decoder each enforce 2 MiB, UTF-8, and NUL boundaries. Generation
  checks and the existing private preview owner prevent late publication and
  remove temporary content on replacement, navigation, close, and shutdown.
- Staging measurements use the exact UUID staging path through the required
  owned master and the existing path/output bounds. Measurement errors are
  advisory and never decide upload success.
- `README.md` and `PRIVACY.md` now describe native JSON preview, measured upload
  progress, temporary content, and session-only measurements without claiming
  persistent content or telemetry.

## Release-hardening follow-up

`RELAYBAR_LIVE_SSH_HOST` and `RELAYBAR_LIVE_REMOTE_PATH` are not configured in
this workspace. A valid JSON preview plus successful, cancelled, replacement,
failed, and nontrivial measured uploads against an isolated writable SSH target
remain useful release-hardening evidence; they are not claimed here and did not
block the user's acceptance of Task 040.
