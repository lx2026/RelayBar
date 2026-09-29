# Changelog

Notable RelayBar changes are recorded here.

## [1.6.0] - 2026-09-29

### Added

- SSH retries use a saved limit from 0 to 100 in Settings (default 10); set
  it to 0 to disable automatic retries. Delays grow from 5 seconds to a
  5-minute cap, and brief reconnects no longer reset the retry budget.
- Remote Files previews bounded UTF-8 JSON with selectable syntax highlighting,
  wrapping, and horizontal scrolling, plus MP4 video with native playback
  controls that start paused.
- Single and bulk remote-file deletion share a five-second Undo window before
  any removal reaches the server. Selection mode supports file-only bulk actions.
- Uploads show byte and percentage progress during transfer.

### Fixed

- Delete controls use destructive styling, and the browser's trash action no
  longer sits beside Download.
- Compact tunnel endpoints, separate host labels, and paths that preserve the
  final folder name make narrow rows easier to distinguish. Narrow Remote Files
  toolbars switch to icons before squeezing the path.
- Profile forms explain the first invalid field beside the disabled save
  button. Forwarding-rule controls fit the popover, and SSH placeholders render
  as plain text.

Deletion is permanent once the Undo window expires and the server accepts it.
Directories and symbolic links are excluded from deletion.

## [1.5.1] - 2026-08-27

### Added

- Named groups keep Start All and Stop All visible at the right side of each
  header, with state-aware enablement and accessible group-specific labels.

### Fixed

- Homebrew installations now register RelayBar's bundle identifier for the
  native upgrade lifecycle: a running app quits before replacement and reopens
  afterward, while an app that was stopped stays stopped.

Existing Homebrew receipts created before 1.5.1 do not gain the new lifecycle
directive retroactively. Run `brew reinstall --cask lx2026/tap/relaybar` once,
or quit RelayBar manually for the first later upgrade.

## [1.5.0] - 2026-08-25

### Added

- A persistent Remote Files split workspace keeps recent folders and recent
  hosts one click away, with bounded recent paths nested beneath each host.
- **Add Path…** opens any validated absolute path through a recent connection,
  saved host, forwarding profile, or concrete SSH-config alias.
- Single-file upload stages data under an app-owned hidden name, then publishes
  only with the server's advertised hard-link or POSIX-rename guarantee.

### Changed

- Remote browsing, previews, downloads, and uploads stay in one resizable
  native window with a hideable sidebar and responsive narrow layouts.
- Opening Remote Files is connection-free until a location is selected; stale
  recent paths remain visible and retryable instead of silently disappearing.

### Security

- Recent history stores only bounded host identities and normalized absolute
  paths locally; directory listings and file content remain session-only.
- Upload conflict handling fails closed for missing SFTP extensions, raced-in
  targets, directories, symbolic links, and SSH-master replacement.
- The universal stable ZIP is signed with a timestamped hardened-runtime
  Developer ID, notarized by Apple, and stapled for offline Gatekeeper
  verification.

## [1.4.0] - 2026-08-18

### Added

- Signed in-app updates with an explicit manual check and optional weekly
  checks. RelayBar still asks before installing and never stops active tunnels
  without a decision.
- A compact Settings footer shows the packaged version and build, copies that
  identity, and links to the project website and repository.

### Changed

- An exact remote Markdown or supported image path opens directly in the
  existing bounded preview. Other regular files remain selected for explicit
  download instead of being treated as directories.
- New and Edit Profile forms keep balanced scrolling insets without reducing
  the usable content width.

### Security

- Sparkle 2.9.4 is pinned exactly, uses the embedded EdDSA public key and signed
  HTTPS appcast, and disables automatic download and installation.
- The universal stable ZIP is signed with a timestamped hardened-runtime
  Developer ID, notarized by Apple, and stapled for offline Gatekeeper
  verification.

## [1.3.0] - 2026-07-30

### Added

- A native in-popover setting can register RelayBar to launch when the current
  user logs in while leaving every saved forwarding profile stopped.
- Named group menus can start inactive members, stop active members, or restart
  only the members that were active when the command began.
- Image and Markdown previews retain the current folder's previewable files in
  a resizable, hideable sidebar with fast mouse and keyboard switching.

### Changed

- Remote Files reuses one private SSH master for folder listings, previews, and
  downloads. Bounded session caching makes Back and revisits immediate while
  stale folders revalidate without blanking their contents.
- Folder opens now show their target path immediately, remain cancellable, and
  preserve the prior folder and selection when an uncached open fails.
- Image previews use a quieter adaptive canvas, and Markdown uses a focused
  reading width with a calmer toolbar and grow-only preview window sizing.

### Fixed

- Remote Files control sockets account for OpenSSH's temporary bind suffix and
  stay within macOS's Unix-socket path limit.
- Superseded navigation and preview work can no longer publish stale content or
  leave its temporary preview directory behind.
- Login-item failures preserve the system-reported state, and the forwarding
  rule type control no longer squeezes its redundant label into a narrow
  column.

### Security

- The universal stable ZIP is signed with a timestamped hardened-runtime
  Developer ID, notarized by Apple, and stapled for offline Gatekeeper
  verification.
- Remote Files owns and removes its private SSH control socket and continues to
  run bounded, separately cancellable SFTP children without adding a new
  network protocol dependency.

## [1.3.0-beta.1] - 2026-07-26

### Added

- A native in-popover Settings screen can register RelayBar to launch when the
  current user logs in, while leaving every saved forwarding profile stopped.
- Named group menus can start inactive members, stop active members, or restart
  only the members that were active when the command began.

### Fixed

- Login-item operation errors preserve the system-reported toggle state so a
  failed change remains truthful and retryable.
- The forwarding-rule type segmented control no longer squeezes its redundant
  **Type** label into a vertical column at the 380-point popover width.

### Security

- The universal beta ZIP is signed with a Developer ID, notarized by Apple, and
  stapled for offline Gatekeeper verification.

## [1.2.1] - 2026-07-26

### Added

- Remote Files can save a standalone SSH host without creating or starting a
  port-forwarding profile.
- The server picker combines recent successful connections, saved hosts,
  forwarding profiles, and concrete aliases from `~/.ssh/config`.
- Standalone hosts can be removed without changing forwarding profiles or SSH
  config.

### Fixed

- The New Profile form now stays inside the 380-point menu width and no longer
  clips its left edge.
- The Group field displays one label instead of repeating the native picker
  label.

### Security

- SSH-config discovery is read-only and bounded to 1 MiB and 256 concrete host
  aliases. Wildcard, character-pattern, and negated aliases are ignored.
- The universal macOS ZIP is signed with a Developer ID, notarized by Apple,
  and stapled for offline Gatekeeper verification.

## [1.2.0] - 2026-07-25

### Added

- Flexible forwarding profiles with repeated and mixed `-L`, `-D`, and `-R` rules over one managed SSH connection.
- Local and remote SOCKS forwarding, TCP and Unix-socket endpoints, reverse-SOCKS destination policy, and OpenSSH-assigned remote ports.
- Optional profile groups with lightweight sections, move, rename, and ungroup actions that do not restart active SSH processes.
- Exact-path Remote Files browsing with navigation, refresh, file and folder downloads, progress, cancellation, and Finder reveal.
- Safe read-only previews for supported remote images and Markdown, including GFM, common Obsidian reading syntax, syntax highlighting, footnotes, callouts, and native math.

### Changed

- Existing single local-forward records migrate to typed one-rule profiles while preserving stable profile data.
- Quick Add imports forwarding-only SSH commands into validated typed rules without invoking a shell.
- Runtime forwarding state, retry behavior, browser actions, socket cleanup, and Remote Files connection reuse operate on the generalized profile model.
- Post-beta reliability work hardens SSH control buffering, restart coordination, directory progress polling, grouping, and error normalization.

### Security

- Forwarding, Remote Files, and preview inputs use bounded structured parsing and fixed executable argument arrays.
- Remote Markdown remains inert: raw HTML is not activated, remote embeds are not fetched, and unsafe links are blocked.
- SFTP cancellation owns child reaping and serializes signal delivery so delayed escalation cannot target a recycled PID.
- Early child exits cannot terminate RelayBar with `SIGPIPE`, and close-by-default spawning preserves batch standard input.
- The universal macOS ZIP is signed with a Developer ID, notarized by Apple, and stapled for offline Gatekeeper verification.

## [1.2.0-beta.1] - 2026-07-24

### Added

- Flexible forwarding profiles with repeated and mixed `-L`, `-D`, and `-R` rules over one managed SSH connection.
- Local and remote SOCKS forwarding, TCP and Unix-socket endpoints, reverse-SOCKS destination policy, and OpenSSH-assigned remote ports.
- Optional profile groups with lightweight sections, move, rename, and ungroup actions that do not restart active SSH processes.
- Exact-path Remote Files browsing through saved SSH connections, including navigation, refresh, file and folder downloads, progress, cancellation, and Finder reveal.
- Safe read-only previews for supported remote images and Markdown, including GFM, common Obsidian reading syntax, syntax highlighting, footnotes, callouts, and native math.

### Changed

- Existing single local-forward records migrate to typed one-rule profiles while preserving stable profile data.
- Quick Add now imports forwarding-only SSH commands into validated typed rules without invoking a shell.
- Runtime forwarding state, retry behavior, browser actions, socket cleanup, and Remote Files connection reuse now operate on the generalized profile model.
- The menu-bar list, editor, README, GitHub Pages site, and product screenshots now reflect profiles and grouping.

### Security

- Forwarding, Remote Files, and preview inputs use bounded structured parsing and fixed executable argument arrays.
- Remote Markdown remains inert: raw HTML is not activated, remote embeds are not fetched, and unsafe links are blocked.
- Release builds retain the hardened runtime, Developer ID signing, notarization, and Gatekeeper verification workflow.

[1.6.0]: https://github.com/lx2026/RelayBar/releases/tag/v1.6.0
[1.5.1]: https://github.com/lx2026/RelayBar/releases/tag/v1.5.1
[1.5.0]: https://github.com/lx2026/RelayBar/releases/tag/v1.5.0
[1.4.0]: https://github.com/lx2026/RelayBar/releases/tag/v1.4.0
[1.3.0]: https://github.com/lx2026/RelayBar/releases/tag/v1.3.0
[1.3.0-beta.1]: https://github.com/lx2026/RelayBar/releases/tag/v1.3.0-beta.1
[1.2.1]: https://github.com/lx2026/RelayBar/releases/tag/v1.2.1
[1.2.0]: https://github.com/lx2026/RelayBar/releases/tag/v1.2.0
[1.2.0-beta.1]: https://github.com/lx2026/RelayBar/releases/tag/v1.2.0-beta.1
