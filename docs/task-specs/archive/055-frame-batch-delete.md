# Task 055 — Frame batch Delete

Status: Complete — installed 2026-10-23

## Outcome

Frame deletes a selection with one host invocation, not one invocation per asset.

## Delivery Boundary

The Frame bridge and fixed remote helper. No RelayBar UI, history or release-version changes. The user's follow-up authorized rebuilding and updating both apps in Applications.

## Work

- Accept a bounded list from retained listings; group all same-name companions in the broker, including arbitrary JSON/TXT suffixes.
- Run one helper process for the batch and return per-asset outcomes, including partial failures.
- Keep permanent Delete immediate, Archive separate, and history unchanged.
- Update mirrored bridge definitions and reject incompatible peers.

## Acceptance

- [x] A 100-item/four-member selection uses one helper invocation. Whole-group Delete/Archive/Restore and JSON/TXT previews pass.
- [x] Changed, missing, or unauthorized targets cannot delete unrelated files; failures do not hide successes.
- [x] Frame integration tests cover one batch request, bounded recursive-listing renewal and stable visible order.
- [x] 351 tests executed, 329 passed, 22 opt-in skips, no failures. Debug build succeeds; mirrored protocol files match; git diff --check passes. [Current bridge contract](../../system-specs/modules/frame-viewer.md) updated.

Companion task: `2026-10-22-smooth-review-and-batch-actions.md` in Frame. Before edits, origin/main was fetched; HEAD is its base with zero divergence. Existing feature changes are preserved.

No private host was opened or mutated; filesystem tests use disposable local fixtures. Applications was updated on 2026-10-23 to RelayBar 1.6.0/17 and Frame 0.1.0/11 (bridge v5), with build-number increments only. Both Release builds and installed deep/strict signatures pass; RelayBar is universal with matching dSYM UUIDs. Both apps launch, and Frame reads the existing three-location catalog. Previous apps are retained in Frame's `.build/backups`; preferences are preserved. Frame removed the old persistent preview cache on launch. Local signed installation only, without notarization, publication, commit or push. Build logs are `.build/applications-update-build.log` in each repository. Real-host latency and interruption boundaries are not claimed as verified.
