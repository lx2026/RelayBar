# Task 042 — File Selection Mode and Bulk Delete Verification

Verified: 2026-08-30

Result: Complete. Implementation, automated checks, system documentation, and
offscreen visual evidence pass. The final source bundle is included in the
locally installed review application described below.

## Automated evidence

- The complete warnings-as-errors Swift suite passed 312 tests with 19 expected
  opt-in live, benchmark, and snapshot tests skipped and no failures.
- Model coverage verifies file-only selection, ordinary-click toggling, a
  mutation-free Cancel path, stable sequential deletion, ordinary-selection
  repair after full success, and stop-on-first-failure retention of failed and
  unattempted selections.
- Existing Task 041 service coverage verifies that every submitted file receives
  a fresh exact-path fingerprint preflight and one shell-free quoted `rm`.
  Directories and symbolic links are rejected before SFTP removal begins.
- The macOS Xcode Debug build passed with the RelayBar target's authoritative
  complete strict-concurrency and warnings-as-errors settings.
- `plutil -lint` passed for the Xcode project and application property list; the
  fake-SFTP fixture passed `sh -n`; and `git diff --check` passed.

## Visual and interaction evidence

`VisualSnapshotHarness/testCaptureTask042To044RemoteFileSnapshots` passed and
produced inspected Aqua and Dark Aqua selection-mode captures. They show:

- the top-level **Select** entry point replaced by an explicit **Cancel** action
  while selection mode owns the folder;
- circular selectors only on regular-file rows, with folders visible but inert;
- two ordinary-click selections, a live `2 Selected` count, and one `Delete 2`
  action area;
- no top-level Delete entry point, confirmation popup, modifier-key affordance,
  drag target, or drag-and-drop deletion UI.

Source and model tests pin Escape/Cancel behavior, zero-selection disabling,
operation gating, session reset, immediate no-confirmation submission, full
success exit, and inline partial-failure retention.

The final temporary captures are in
`/tmp/relaybar-042-044-complete.kum95L`; they are reproducible verification
output rather than repository assets.

## Security and lifecycle evidence

- Selection stores only current-folder regular-file identities and cannot span
  folders, hosts, windows, or sessions.
- Batch deletion processes the stable visible order sequentially and stops at
  the first non-acknowledged result. It does not retry or infer success.
- Every item reuses Task 041's current-session generation ownership, exact-path
  revalidation, literal command construction, outcome classification, cache
  reconciliation, and same-name-recreation handling.
- No selection or deletion history, telemetry, Trash integration, quarantine,
  undo store, or persistent remote-content state was added.

## Release-hardening follow-up

No isolated writable live SSH fixture is configured. Multi-file success,
permission denial after an acknowledged prefix, same-name replacement, and
transport loss remain useful release-hardening checks in a non-production
directory; they are not claimed here.

## Local review installation

At the user's explicit request, the Developer-ID-signed arm64 Debug review
build was installed and launched at `/Applications/RelayBar.app`. Deep signature
verification passed, and the installed executable's SHA-256
`cabc7ef244cc8428c72fe2e99e4fb6bd267574007428ccc1b9a3dfd89ae8ee79`
matches the verified source bundle. The previous installed review app and source
bundle are preserved at `.build/RelayBar-040-041-installed.app` and
`.build/RelayBar-040-041-source-build.app`. No release, publication, push, or
remote deployment was performed.
