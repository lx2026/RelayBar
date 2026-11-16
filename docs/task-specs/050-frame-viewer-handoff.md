# Task 050 — Frame viewer handoff

Status: Implemented and locally installed — native first-host acceptance pending
Created: 2026-10-22

2026-11-08 reconciliation: the work below records the original handoff design. [Task 051](archive/051-explicit-frame-history.md) superseded Frame's history writes, and [Task 053](archive/053-frame-direct-delete.md) superseded the read-only operation boundary. Current linked-app access and protocol v6 are defined in the [system spec](../system-specs/modules/frame-viewer.md). The remaining native handoff, focus and offline-recovery acceptance is also required by [Task 058](058-composable-app-architecture.md); that task must record current signed-app evidence before this task can be accepted.

## Outcome

The user requested one-click Open in Frame from RelayBar and shared saved hosts / path history. They chose RelayBar-owned SSH connections and a disabled download fallback until a real website exists. Frame owns local favorites; RelayBar owns remote connection settings and history. UI/UX received two Fable 5.1 requirements-only reviews in the Frame project.

## Work

- Open the current folder and focused media / matching JSON in Frame.
- First-use read-only consent in RelayBar; revoke in Settings.
- Authenticate both running peers by audit token, expected bundle ID and Developer ID team. A short-lived one-use URL nonce is only a handoff, not authority.
- App Group UNIX socket; bounded catalog/list/fetch/status/cancel/release protocol. Reuse SSH/SFTP service, retain aliases and host-key checks. No upload/delete/archive/shell API.
- Use the same live RemoteServerCatalog as RelayBar's existing browser. No credentials or copied host database in Frame.
- Missing or incompatible Frame explains next steps; no placeholder download URL.

## Acceptance

- [x] Positive signed sandbox-client bridge and wrong-identity rejection verified; installed handshake passed.
- [x] Consent/revoke, unsupported protocol/operations, malformed paths and read bounds tested.
- [x] Successful Frame listing updates existing history in tests; no duplicate catalog owner.
- [ ] Native browser and preview handoff UI reviewed; correct focus and offline recovery verified.
- [x] Full tests and packaged universal build pass, including nested signatures and app-group entitlement.
- [x] System specs and [verification evidence](../verification/050-frame-viewer-local-install.md) reflect delivered behavior and remaining acceptance.

## Delivery Boundary

No commit, push, PR, release, notarization, feed or website change is authorized. The user explicitly approved updating both Applications bundles and a brief tunnel interruption; installation retained recoverable backups. Live first-host acceptance still requires a user-selected folder. Keep this task active until the native acceptance item passes.
