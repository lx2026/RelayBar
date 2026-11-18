# RelayBar → Frame handoff and shared remote history

Status: Implemented and installed — first-host handoff acceptance pending
Created: 2026-10-22

## Objective

Open RelayBar's current remote folder in Frame's full viewer with one click after initial authorization, retaining RelayBar's existing SSH setup and one shared remote-location history.

## Confirmed decisions

- User chose RelayBar to manage remote connections for Frame; remote browsing requires RelayBar running. Local viewing remains independent.
- RelayBar owns host definitions, SSH config/agent/key access, host-key checks, and the recent-location catalog. Frame does not copy credentials or create a competing host catalog.
- Successful folder opens from either app update RelayBar's same catalog. Frame favorites remain private.
- A selected media file or paired JSON focuses its asset. Folder handoff opens the Contact Sheet; unsupported files do not trigger downloads.
- The user chose to leave the download link disabled until a real Frame download website exists. Missing/incompatible Frame gets a clear message, never a placeholder URL.

## Work and boundaries

Add a narrow authenticated local bridge with only catalog, folder listing, bounded file reads, cancellation, and recent-location recording. Reuse RelayBar's existing SSH transport rather than reimplement aliases/jump hosts in Frame. Remote upload, deletion, Archive, and shell commands are not bridge capabilities.

Preserve Frame's App Sandbox. Both production peers must have verified expected bundle/team identities; a URL scheme is only a wake-up signal, never connection authority. Validate bounded messages and every path. Transfer/cache failures must not become blank metadata or stale selection. Remote cache paths never enter local destructive actions.

Show saved/recent locations before manual path entry. The primary label identifies `location · via RelayBar`. When RelayBar is unavailable, show Open RelayBar/Retry in the remote view; local navigation still works. First authorization happens once in RelayBar and must be revocable.

## Acceptance

- [x] User confirmed the connection owner and disabled-download-link behavior.
- [x] Two read-only UX review rounds completed; requirements only, no RelayBar source or private records shared.
- [x] Signed peer authentication and preserved sandbox verified with isolated fixtures and the installed peer handshake.
- [ ] One-click RelayBar handoff focuses the correct media/JSON asset without reconnecting an unrelated host.
- [x] Remote browsing/export use bounded cancellable transfers; local Trash/Archive unavailable remotely. Isolated exact-download/cache/cancellation tests pass.
- [x] Both apps use one live catalog; successful Frame listings update it in tests. Host selection alone does not connect. Native two-app history round trip remains part of live acceptance.
- [ ] Missing app, old protocol, denied/revoked authorization, offline host, stale result, malformed path, oversized media, and cancellation are tested.
- [x] Native local-assets and installed remote-consent screenshots recorded; both local builds updated with recoverable backups. Full native host handoff remains unchecked above. No publication/notarization performed.

[Verification, screenshots, hashes and remaining checks](../system-specs/verification-2026-10-22.md).

## Review record

Design review, two successful rounds. Round 1 favored locations over credentials and warned that URL schemes cannot authenticate callers. Round 2 recommended RelayBar-owned connections once existing aliases/jump hosts and Frame's sandbox were made explicit. Its suggested bearer-token transport is advisory, not a verified security design; implementation must authenticate peers. Sidecar metadata should follow Capture and precede collapsed Embedded metadata, without merging generation fields.
