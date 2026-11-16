# 054 — Development version correction

Status: Complete
Created: 2026-10-22

## Outcome

Revert development-only marketing-version bumps to RelayBar 1.6.0 and Frame 0.1.0. Keep internal builds 16 and 10 and all current functionality.

## Delivery Boundary

Version metadata, repository instructions, current-state documentation and signed local Applications updates only. No source-feature rollback, publication, tag or release-channel change.

## Work

- Restore marketing labels in packaging and both RelayBar Xcode configurations.
- Add the rule to both `AGENTS.md` files: local development/rebuild/install requests never authorize marketing-version bumps; only build numbers advance as needed.
- Rebuild/sign, verify matching versions/builds and install both apps while preserving preferences and prior bundles.

## Acceptance

- [x] Installed Frame is 0.1.0/10 and RelayBar is 1.6.0/16; signed builds and relaunch verified.
- [x] Both repository instruction files contain the development-versioning rule.
- [x] Current documentation reflects corrected labels; historical delivery records retain dated corrections.

[Verification](../../verification/054-development-version-correction.md).
