# Tasks 046–048 — Remote Files and Editor Usability Verification

Verified: 2026-09-28

Result: Complete. The five-second deletion Undo window, readable connection and
path labels, and profile-editor validation/layout corrections are implemented.

## Automated and build evidence

- Final `swift test -Xswiftc -warnings-as-errors`: 328 tests, 21 opt-in live,
  benchmark, and snapshot skips, no failures (307 passed).
- Undo tests verify the production five-second deadline, no service submission
  before expiry, single and bulk Undo surviving the original deadline, preserved
  rows/selection, submission only after expiry, and cancellation on close.
  Existing deletion tests use an injected zero delay to verify acknowledged
  browser/preview advancement, same-name recreation, rejection, unknown outcomes,
  sequential batches, partial failure, and preserved unattempted selection.
- Presentation tests verify compact localhost summaries without changing SSH
  or copied values, explicit/wildcard bindings, IPv6 brackets, allocated ports,
  missing/invalid ports, Remote SOCKS, and Unix-path validation.
- Xcode Debug build passed with the app target's complete strict-concurrency
  and warnings-as-errors settings. Command: `xcodebuild -project
  RelayBar.xcodeproj -scheme RelayBar -configuration Debug -derivedDataPath
  .build/Task045 -clonedSourcePackagesDirPath
  .build/Task033StrictV2/SourcePackages -disableAutomaticPackageResolution
  CODE_SIGNING_ALLOWED=NO build`.
- App/project property-list lint and `git diff --check` passed.

## Visual evidence

With `RELAYBAR_SNAPSHOT_DIR=/tmp/relaybar-046-048-snapshots`, these four snapshot
tests passed: `testCaptureTasks046To048Snapshots`, `testCaptureTask021Snapshots`,
`testCaptureTask025Snapshots`, and `testCaptureTunnelListSnapshots`. The new
matrix was recaptured successfully after adding the native window background
to the two editor fixtures.

Inspected light/dark captures confirm:

- Bulk **Delete 2** is red and distinct from Cancel. During the wait, the strip
  says **Will delete 2 files**, shows the remaining Undo time, and exposes Undo.
  Rows remain present until acknowledged deletion; the UI does not claim that
  unsubmitted requests have already deleted server files. The row trash button
  beside Download is removed.
- At the 760 × 440 workspace minimum, toolbar actions use icons and the path
  retains `build-artifacts`. Single-host recents show distinct final folder
  names and path suffixes without a repeated host prefix. Full values remain
  available through help and accessibility, and host names/SSH identities have
  separate lines.
- Tunnel rows show compact values such as `:8000 → :3000` without changing
  actual forwarding or copy values.
- New/Edit profile cards have visible right borders. Local and Remote SOCKS
  menu controls fit, host placeholders have plain styling, and the fixed save
  area explains the invalid rule even while its port is below the fold.
  Editor snapshot assertions also verify horizontal containment.

Captures and build/test logs are reproducible temporary evidence under
`/tmp/relaybar-046-048-snapshots` and `/tmp/relaybar-046-048-*.log`.

## Lifecycle and live scope

Undo cancels only a pending client-side request and invalidates its generation.
There is no recovery promise once submission begins. Exact-path preflight,
sequential SFTP removal, no automatic retry, and truthful partial/unknown
results remain in force. Close/quit during the delay sends no deletion; close
after submission retains the existing bounded retirement path. No deletion
queue or history is persisted.

No live server was used for destructive verification. Tests and visual fixtures
use isolated fake services; opt-in live tests are not claimed as passing. No
remote production file was deleted, and no release or deployment was published.

## Local installation

The signed Debug app containing these three fixes and Task 045's retry changes
was installed and launched at `/Applications/RelayBar.app`. Deep strict
signature verification passed. The installed executable matches the signed
staged build with SHA-256
`976f9f6a3307252e8b9c917f5e0ecfc7414456f52478334022113eb22b042345`.
The preceding retry-only build is preserved at
`.build/RelayBar-before-046-048-install.app`; the build before Task 045 remains
at `.build/RelayBar-before-045-install.app`.
