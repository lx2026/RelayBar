# Verification

## Required checks

- Run `swift test` for parsing, safety, retry, cancellation, and browser URL behavior.
- Build the Xcode app target with warnings treated as errors.
- Run `git diff --check` before committing.

## Optional live check

Set `RELAYBAR_LIVE_TEST=1` and `RELAYBAR_LIVE_SSH_HOST` to test a real SSH forward and HTTP response on local port 3000.

Release changes should additionally verify the code signature and notarized app with the scripts in [Build and release](build-and-release.md).
