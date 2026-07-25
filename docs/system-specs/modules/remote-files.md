# Remote Files

Remote Files opens an exact folder on a saved SSH server without adding search, indexing, mounting, or editing.

## Entry and window

- A labeled **Remote Files…** row appears below the tunnel list.
- The row opens or focuses one separate native window.
- The launcher requires an absolute remote path and a saved server.
- The server picker collapses forwarding presets that have the exact same SSH host and SSH arguments into one SSH-host entry. Group tags and forwarding-rule differences do not split equivalent connections. Different host aliases or SSH arguments remain separate because they may select different credentials, ports, or routes.
- A single Quick Add tunnel whose generated name matches its forwarded destination is labelled by its SSH host in the server picker. An intentional custom name remains visible with the SSH host for context when that SSH connection is not duplicated.
- A successful open changes the compact launcher into a wider browser window.
- Missing-path output from SFTP is normalized to a short user-facing error while preserving the entered path and server for retry.

## Folder browser

- The top bar contains **Back**, the exact current path, and **Refresh**.
- The list shows supported folders, regular files, and symbolic links with modified text and size.
- Folders sort before other items; each group uses localized name ordering.
- Opening a folder navigates into it. Back follows navigation history, reselects the folder that was left, and returns to the launcher from the initial folder.
- Supported images and Markdown documents open the preview state. Other files begin destination selection for download.
- Search, filters, indexing, workspace discovery, rename, move, delete, upload, and remote editing are absent.

## Downloads

- Regular files use the macOS save panel.
- Folders use a directory chooser and recursive SFTP retrieval.
- One transfer runs at a time.
- A temporary strip reports progress, supports cancellation, and offers **Reveal in Finder** after completion.
- Back navigation is disabled in every browser folder while a transfer is active or still cleaning up.
- Transfer progress and state icons expose explicit accessibility descriptions rather than relying on system-symbol names.
- Downloads use a hidden, fixed-length UUID staging directory beside the destination. The directory is created with mode `0700` before SFTP writes its payload, and its bounded name avoids exceeding local filesystem limits when the chosen destination name is long. Existing content is replaced only after the new transfer succeeds.
- Cancellation and failure remove the complete staging directory and leave an existing destination unchanged.
- Cancellation and failure messages explicitly state that temporary data was removed and existing files were unchanged.
- Transfer progress is scoped to its originating attempt; a delayed callback from a failed or cancelled attempt cannot update a retry.
- Single-file progress polls every 250 ms. Recursive progress re-walks the partial tree, so its interval scales with the entry count from 1 second up to a bounded 8 seconds. The completion report is exact regardless of interval.
- A cancelled transfer escalates to `SIGKILL` only while the process is recorded as still running; a process observed to have exited is never signalled again.

## Image preview

- PNG, JPEG, GIF, HEIC/HEIF, TIFF, and BMP files are previewable.
- Preview retrieval is limited to 100 MiB.
- Bounded native ImageIO thumbnail decoding runs off the main actor from private temporary storage; only the completed immutable image is published back to the UI.
- Leaving the preview or closing the window removes preview content, including when cancellation happens after retrieval but during decoding.
- Preview has no gallery, metadata inspector, markup, or editing behavior.

Empty folders show a single focused empty state with an explicit accessibility description.

## Markdown preview

- `.md`, `.markdown`, `.mdown`, and `.mkd` files use the same focused preview state.
- Preview retrieval is limited to 2 MiB and accepts UTF-8 without NULs.
- The reader is selectable and read-only; it does not fetch document images, resolve remote embeds, execute HTML or Mermaid, or write remote content.
- Detailed behavior and limits live in [Markdown preview](markdown-preview.md).

## Transport and lifecycle

- RelayBar invokes `/usr/bin/sftp` directly and never invokes a shell.
- Remote and local batch paths are limited to 32 KiB of UTF-8 before quoting.
- Quoting satisfies the sftp tokenizer but not its globber, so a remote argument containing `*`, `?`, or `[` is refused with a message naming those characters rather than sent for expansion. The refusal happens before any process launches. Local destinations are resolved literally and may contain those characters.
- A listing whose entries carry those characters still parses and still renders every row; only opening or downloading such an entry is refused.
- Captured standard output is capped at 32 MiB and standard error at 1 MiB.
- Parsed listing lines are limited to 32 KiB, entry names to 4 KiB, entry sizes must be nonnegative, and supported entries remain capped at 10,000.
- Listing rows may contain either basenames or absolute paths. An absolute entry is accepted only when it is a direct child of the requested folder, then reduced to its basename; out-of-folder absolute entries fail closed.
- RelayBar does not add SFTP quiet mode implicitly, so bounded diagnostics retain actionable host-key, resolution, timeout, refusal, and connection-loss details for normalization. A user-saved `-q` option is still preserved.
- Safe connection options are translated for SFTP, including SSH `-p` to SFTP `-P` and SSH `-l` to `User=`.
- The user's normal OpenSSH config, identities, agent, jump host, and host-key behavior remain in effect.
- Browsing is independent of the local-forward process state.
- Closing the Remote Files window or quitting RelayBar cancels listing, preview, and transfer work.

See [Security boundaries](../shared/security-boundaries.md).
