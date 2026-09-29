# Task 044 — MP4 Video Preview

Status: Complete

Created: 2026-08-30

Completed: 2026-08-30

Follows: Task 040

## Outcome

Opening a supported remote `.mp4` regular file presents a native, read-only
video preview with familiar playback controls inside the existing Remote Files
preview workspace.

## Delivery Boundary

### Included

- Case-insensitive `.mp4` classification for regular files and direct paths.
- Private, cancellable retrieval with explicit progress and a documented size
  bound before native AVFoundation/AVKit playback.
- Play, pause, scrub, volume, time, and full-screen controls without autoplay.
- Existing preview-sibling navigation, Download, direct Delete, temporary-file
  cleanup, generation isolation, and close/quit ownership.
- Clear errors for an oversized file, failed retrieval, unsupported codec, or
  unreadable media.

### Excluded

- Editing, trimming, transcoding, thumbnails, playlists, subtitles, casting,
  remote HTTP playback, or background playback.
- Claiming every codec permitted by the MP4 container is playable.
- Persisting video bytes, playback position, history, metadata, or thumbnails.

## Work

- Define and document a video retrieval limit that is practical for remote
  preview and does not weaken current path, output, process, or disk-lifecycle
  bounds. Show retrieval progress and allow cancellation before playback.
- Store bytes only in an app-owned private temporary directory, hand the local
  URL to a native player, and release both player and file on sibling switch,
  Back, host/path change, close, or quit.
- Integrate MP4 with previewable sibling ordering and keyboard focus without
  stealing media keys or starting playback automatically.
- Add classification, limit, cancellation, stale callback, cleanup, playback
  readiness, unsupported-codec, direct-path, sibling, deletion, and visual/
  accessibility coverage.

## Acceptance

- A supported bounded MP4 opens in the existing preview workspace and remains
  paused until the person starts playback; standard native controls work.
- Retrieval progress, cancellation, oversize, transport, and codec failures are
  explicit and never leave temporary bytes after the preview lifecycle ends.
- Switching siblings, deleting the previewed file, navigating Back, closing the
  window, and quitting stop playback and cannot publish stale media state.
- Automated, visual, accessibility, lifecycle, system-spec, and
  `git diff --check` evidence pass before completion. Isolated live-SSH review
  is recorded when a writable fixture is configured; otherwise it remains an
  explicit release-hardening follow-up and is not claimed as passing.
