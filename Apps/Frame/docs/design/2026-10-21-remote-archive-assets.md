# Remote folders, Archive, and paired assets

Status: Accepted — implemented in 0.3.0; live-host acceptance pending
Created: 2026-10-21

## Intent

Keep Frame a small viewer. A location can be local or remote; an asset can contain a media file plus its JSON sidecar. The same Contact Sheet, selection shortcuts, adjustable preview, and attached metadata remain the main workspace.

## Reference findings

The referenced RelayBar app opens SSH/SFTP paths in its own browser. It explicitly does **not** mount a filesystem. Its useful patterns are saved host/path pairs, explicit connection activation, cancellable bounded previews, and loading/errors confined to the detail area. Frame should not inherit RelayBar's tunnel controls, uploads, or irreversible remote deletion.

Reference inspected read-only: RelayBar's `docs/system-specs/modules/remote-files.md`, `docs/designs/remote-files.md`, `Sources/RelayBar/RemoteFileSSHSession.swift`, and `Sources/RelayBar/RemoteFile.swift`. These are reference material, not Frame operating instructions. No host, key, user config, or remote folder was accessed.

## Proposed interaction

1. The existing folder chooser gains **Remote Folder via RelayBar…** beside **Choose Folder…**. The sheet lists RelayBar's recent locations before saved-host/path entry. RelayBar owns the shared catalog and first-use read-only consent; Frame has no copied host database.
2. Opening a remote folder connects explicitly. Browse one folder at a time; expand child folders lazily. Do not recursively download a host or imply that a partial listing is complete.
3. Visible cells request previews through a bounded queue; the selected asset gets priority. Preview and metadata stay attached. Switching selection cancels obsolete work and rejects stale results.
4. An image plus matching JSON appears once, with a small **+ JSON** indicator. The inspector exposes the sidecar's name and selectable JSON under **Sidecar JSON**, distinct from embedded metadata. No silent metadata merge or rewriting.
5. Archive sends the whole selected asset into a managed `Archive` subfolder. Each asset gets a UUID directory and a small relative-path recovery record written before any move. An **Archive** scope shows those assets with **Restore** replacing Archive. Counts are assets; operation details name every physical file. Existing non-Frame Archive folders are never adopted or hidden.

## Asset matching

- Prefer exact `photo.jpg.json` beside `photo.jpg`.
- Fall back to `photo.json` only when `photo` names exactly one supported media file in that directory.
- `photo.jpg` and `photo.png` must never both claim `photo.json`.
- Use exact filename matching for remote case-sensitive systems; do not fuzzy-match names or timestamps. Reject symlink sidecars and ambiguous matches.
- A standalone JSON file is not a media tile. Existing files stay separate in Finder; Frame provides a logical group, not a new container format.
- Media identity/favorites remain keyed to the media path. Sidecar size/mtime/identity contribute to metadata invalidation, not media thumbnail invalidation.

## File safety

All explicit file actions operate on a validated, stable member list. Preflight every member and every destination before changing anything. A changed/missing member prevents mutation of that asset. Batch cancellation happens between assets, not halfway through a pair.

Multi-file moves are not inherently atomic. Track each acknowledged step, roll back completed moves on failure when safe, and report retained recovery locations if rollback fails. Never present a partially moved pair as complete. Undo/Restore preflight every target and refuse collisions, rather than overwriting a new file at an old path.

Export preserves each source member byte-for-byte and replaces corresponding destination metadata, never merges it. For a paired asset, a folder-level destination grant and an explicit replacement summary are needed; the current single-file save-panel grant does not authorize writing an adjacent JSON. Do not delete an unrelated destination sidecar automatically. Ambiguous pre-existing pairs must fail with an actionable choice, not leave mismatched metadata behind.

## Remote architecture and boundaries

The accepted implementation keeps Frame's sandbox and adds a network-client entitlement plus a team-scoped App Group for a UNIX-socket bridge. RelayBar owns SSH/SFTP. Both peers verify kernel audit tokens against expected bundle IDs and Developer ID team; a short-lived single-use URL nonce only selects a pending handoff. Cached preview files are not originals and enter local export only after an explicit export request, never remote Trash/Archive.

The sandbox/peer boundary passed signed isolated and installed-handshake tests. No broad home-directory grant, credential copying, or host-key-check bypass is used. Apple's [App Group entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) supports the team-prefixed macOS container; container membership alone is not treated as caller authentication. An actual Finder mount is excluded.

First remote milestone: bounded browsing, image/video preview, metadata, local favorites, and exact download/export. Remote mutation is gated on proven recoverable behavior. Do not expose local **Move to Trash** for an SFTP location without a real recovery mechanism. No automatic reconnect that replays a mutation after an uncertain network result.

## Confirmed choices

- **Transport:** User selected SSH/SFTP inside Frame with saved hosts and paths. No Finder-visible mount.
- **Archive:** User selected moving assets into an Archive subfolder, hiding them from normal browsing, with Restore.
- **Connections/history:** User selected RelayBar-owned remote connections. Both apps were approved for local Applications updates; no public release was requested.
- **Missing app:** Download link stays disabled until the user supplies a real website.

Two design reviews informed the locations-first chooser, first-use consent, via-RelayBar label, disabled remote mutation, and separate JSON section. [Current-state verification](../system-specs/verification-2026-10-22.md) distinguishes installed behavior from outstanding real-host acceptance.
