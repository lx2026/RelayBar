# Pre-release review fixes

Status: Implemented — 2026-11-17. Automated checks pass; [verification](../verification/070-pre-release-review-fixes.md). A second review of the fixes and the owner's acceptance are open.

## Outcome

The defects found by an independent source review of the 2.0.0 pull request and by its first CI runs are fixed, each with a regression test, before any public beta.

## Delivery Boundary

Fixes only, in both apps, the shared bridge channel and the appcast script. No new features, no change to the bridge wire format, the remote archive's on-disk format, versions or build numbers. No release, feed, website or Homebrew change.

## Work

- RelayBar never lets a remote reply name a local file, and removes only the temporary folder it created.
- Frame serves a document page only from the library it was loaded for.
- Frame's exports never replace a file the person did not agree to replace.
- Remote Restore refuses a replaced archived file or an unexpected file, and one damaged archive record no longer hides the others.
- The bridge channel closes each connection once, after its queued writes.
- A malformed remote reply is refused instead of crashing Frame.
- A file Frame fetches through RelayBar is bounded by the bridge's limit, not RelayBar's own preview limits.
- The appcast script refuses an archive that is not signed, stapled and accepted by Gatekeeper, and replaces the feed only after verifying the new one.
- Opened-time records are dropped after a permanent remote delete, and an empty remote folder gets its change baseline when first expanded.
- With Paper Appearance off, the panel and status colours stay readable on macOS 13 to 15; RelayBar builds with the Xcode that CI uses; tests that depended on the newest macOS or on a burst of connections are made sound.

## Acceptance

- Every finding has a regression test that failed before its fix, or a stated reason why none was practical.
- `scripts/test.sh`, both app builds and `git diff --check` pass locally and in CI on macOS 15.
- The system specs describe the changed behaviour, and a verification record lists each finding, its fix and its test.
