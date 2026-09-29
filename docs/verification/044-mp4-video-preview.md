# Task 044 — MP4 Video Preview Verification

Verified: 2026-08-30

Result: Complete. Bounded MP4 retrieval, native paused playback, automated
checks, system documentation, and Aqua/Dark Aqua visual evidence pass. The final
source bundle is included in the locally installed review application described
below.

## Automated evidence

- The complete warnings-as-errors Swift suite passed 312 tests with 19 expected
  opt-in live, benchmark, and snapshot tests skipped and no failures.
- Classification tests verify case-insensitive `.mp4` regular files only and
  direct MP4 paths. Service coverage rejects an oversized video before SFTP is
  launched and reports measured retrieval bytes.
- AVFoundation coverage creates a valid two-frame H.264 MP4, verifies that it is
  playable and carries a video track, rejects malformed media, and verifies
  that the native player installs media at rate zero and releases it on stop.
- Model coverage verifies measured progress publication, successful URL
  publication, cancellation, unsupported-codec cleanup, Back cleanup, direct
  paths, and deleting the previewed video before advancing to the next
  previewable file.
- The macOS Xcode Debug build passed with the RelayBar target's authoritative
  complete strict-concurrency and warnings-as-errors settings.
- `plutil -lint` passed for the Xcode project and application property list; the
  fake-SFTP fixture passed `sh -n`; and `git diff --check` passed.

## Visual and accessibility evidence

`VisualSnapshotHarness/testCaptureTask042To044RemoteFileSnapshots` passed and
produced inspected Aqua and Dark Aqua MP4 captures. The retrieval state shows a
determinate 50% bar, `9.2 MB of 18.4 MB`, an explicit Cancel action, and disabled
Download/Delete controls while retrieval owns the preview. The ready state is
hosted by native `AVPlayerView`; in the offscreen harness it remains paused and
may show the native readiness spinner rather than advancing a video frame.

Source and automated tests pin the Video label and icon, player accessibility
label, native inline controls including full screen, no autoplay, and cleanup on
replacement or teardown.

The final temporary captures are in
`/tmp/relaybar-042-044-complete.kum95L`; they are reproducible verification
output rather than repository assets.

## Security and lifecycle evidence

- Video preview is limited to 512 MiB before retrieval. Bytes are downloaded by
  the existing bounded SFTP child into an app-owned private temporary directory
  and never streamed through HTTP or a web view.
- AVFoundation validates playability and the presence of a video track before
  publication. Unsupported or unreadable media fails closed.
- Sibling switch, Back, deletion, session replacement, close, and shutdown
  cancel owned work, pause and clear the player, reject stale callbacks, and
  remove temporary bytes.
- Playback position, media bytes, thumbnails, file names, and retrieval progress
  are not persisted or sent as telemetry.

## Release-hardening follow-up

No isolated writable live SSH fixture is configured. Supported/unsupported
codec samples, slow retrieval cancellation, deletion during preview, sibling
switching, close/quit, and limit behavior against a non-production server remain
useful release-hardening checks; they are not claimed here.

## Local review installation

At the user's explicit request, the Developer-ID-signed arm64 Debug review
build was installed and launched at `/Applications/RelayBar.app`. Deep signature
verification passed, and the installed executable's SHA-256
`cabc7ef244cc8428c72fe2e99e4fb6bd267574007428ccc1b9a3dfd89ae8ee79`
matches the verified source bundle. The previous installed review app and source
bundle are preserved at `.build/RelayBar-040-041-installed.app` and
`.build/RelayBar-040-041-source-build.app`. No release, publication, push, or
remote deployment was performed.
