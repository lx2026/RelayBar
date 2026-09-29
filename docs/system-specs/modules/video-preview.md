# Video Preview

Video preview is a bounded native playback state inside the Remote Files
preview workspace.

## Entry and retrieval

- A regular file ending in `.mp4`, case-insensitively, is previewable from a
  folder listing, sibling list, or direct absolute path. The MP4 container does
  not imply that every codec is supported.
- Retrieval uses the active owned SSH master and a private `0700` preview
  directory. A known size above 512 MiB is rejected before transfer, and an
  unknown or changing transfer is aborted if its local payload crosses that
  bound.
- While retrieving, the detail shows monotonic bytes and a percentage when the
  remote size is known. Completion remains below 100% until retrieval succeeds;
  native media preparation is named separately. Cancel ends the SFTP child and
  cannot publish a late callback.
- AVFoundation requires a playable asset with at least one video track before
  the local URL reaches the player. Oversize, transport, unreadable-media, and
  unsupported-codec failures retain Back, retry, and Download.

## Playback and lifecycle

- An embedded `AVPlayerView` supplies play, pause, scrub, time, volume, and
  full-screen controls. Installing an item never calls Play, so every new video
  remains paused until the person starts it.
- The player and temporary bytes are session-only. Switching siblings, direct
  deletion, Back, host or path change, window close, and app quit pause the
  player, clear its item, cancel outstanding work, and remove the preview
  directory. Preview generations prevent superseded retrieval or validation
  from publishing.
- Video preview does not transcode, edit, trim, generate thumbnails, persist
  position or metadata, cast, fetch HTTP media, or continue in the background.

See [Remote Files](remote-files.md) and
[Security boundaries](../shared/security-boundaries.md).
