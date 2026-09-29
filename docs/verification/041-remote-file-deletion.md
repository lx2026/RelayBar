# Task 041 — Direct Remote File Deletion Verification

Verified: 2026-08-30

Result: Complete. The single-file implementation, focused automated checks,
system documentation, offscreen visual evidence, and installed local review
build passed and were accepted on 2026-08-30.

## Automated evidence

- The warnings-as-errors focused run covering the Remote Files model, JSON and
  upload presentation, and SFTP service passed 92 tests with one expected live
  test skipped and no failures after the unapproved multi-selection work was
  removed.
- The complete warnings-as-errors Swift suite passed 297 tests with 18 expected
  opt-in live, benchmark, and snapshot tests skipped and no failures. The final
  040/041 snapshot run passed and produced ten Aqua and Dark Aqua captures.
- Service coverage verifies exact fingerprint revalidation, one quoted removal
  of a literal-metacharacter path, no removal after stale size, directory and
  symbolic-link refusal, acknowledged success, server rejection, and unknown
  outcome after submission interruption.
- Model coverage verifies immediate no-confirmation deletion, next-row repair,
  next-image and earlier-image advancement, no-images browser fallback,
  same-name recreation, accessibility announcements, rejected and unknown
  outcome non-advancement, current-folder reconciliation, and operation gates.
- Existing command-builder coverage pins quotes, backslashes, and literal `*`,
  `?`, and `[` behavior without shell or glob expansion.

## Visual and interaction evidence

The inspected Aqua and Dark Aqua captures show:

- a selected regular-file row with direct trash and download actions;
- a preview toolbar with a visible **Delete** button and no ellipsis;
- an in-place **Deleting 01-dashboard.png…** strip with no Cancel action while
  preview, sidebar, navigation, Download, and further Delete controls are
  disabled;
- acknowledged deletion remaining in preview and advancing to
  `02-metrics.png` without an alert, sheet, popover, tray, or drag target.

Source and model tests additionally pin the final destructive context-menu
item, focused Command-Delete routing, named accessibility action, and macOS
announcement wording.

The final temporary captures are in `/tmp/RelayBarTask040041Final.d9rUSJ`;
they are reproducible verification output rather than repository assets.

## Security and lifecycle evidence

- Deletion accepts one current regular file. It acquires the active owned-master
  token, lists the exact path through that token, compares path, kind, size, and
  modification text, and builds one `SFTPCommandBuilder.removeCommand` batch
  input without invoking a shell.
- Stale and pre-submission failures send no remove. Server failure is rejected;
  loss after invocation is outcome unknown. Neither path retries automatically,
  and a current listing is required before another attempt.
- The parent cache receives the authoritative refreshed listing. A raced-in
  same-name entry remains visible. Deletion owns a separate task and generation,
  and shutdown retains the mutation owner until its child is reaped.
- File names, fingerprints, outcomes, and announcements are session-only; no
  history, telemetry, remote Trash, quarantine, undo, or persistent content was
  added.

## Release-hardening follow-up

No writable live SSH fixture is configured. Direct browser and image-preview
deletion, permission denial, literal metacharacter names, same-name replacement,
transport interruption, close/quit, and excluded directory/link behavior remain
useful release-hardening checks in an isolated non-production directory; they
are not claimed here and did not block the user's acceptance of Task 041.

## Local review installation

At the user's explicit request, the Developer-ID-signed arm64 Debug review
build containing only the accepted 040/041 scope was installed and launched at
`/Applications/RelayBar.app`. Deep signature verification passed and the
installed executable's SHA-256 matched the verified source bundle. The removed
unapproved native-multi-selection review build is preserved at
`.build/RelayBar-native-multiselect-review.app`; the prior signed and notarized
1.5.1 application remains preserved at `.build/RelayBar-previous-installed.app`
and `.build/RelayBar-1.5.1-review-backup.app`. No release, publication, push, or
remote deployment was performed.
