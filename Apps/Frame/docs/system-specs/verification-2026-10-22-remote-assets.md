# Remote asset verification

Date: 2026-10-22
Installed: Frame 0.6.0/9 and RelayBar 1.8.0/15 in Applications; bridge v3.

## Automated evidence

- Frame: 78 tests passed, zero failures, using swift test -Xswiftc -warnings-as-errors.
- RelayBar: 346 executed, 324 passed, 22 existing opt-in/live/visual tests skipped, zero failures. FRAME_HELPER_PYTHON selected the existing local Python 3.12/Pillow runtime for disposable helper fixtures. No package was installed.
- Host-helper coverage: paired Archive/Restore, Trash across new processes, Archive → Trash → original-path Restore, occupied destinations, stale same-sized content, symlinks/traversal, unmanaged Archive, escaping manifests, second-member failure rollback, image/video poster metadata, conditional fingerprints and fixed-command/stdin transport.
- Broker coverage: read consent alone cannot mutate, exact sidecar ownership cannot be claimed twice, protocol rejection and history-neutral Frame opens/listings.
- Client coverage: cold previews never fetch originals; cache reuse across fresh clients; fingerprint invalidation; concurrent request sharing; bounded eviction; missing dependency never falls back to originals; expired batch capabilities renew without history writes and refuse changed assets.
- Existing selection, local file actions, metadata, tree and cancellation tests remain passing.

Logs in each repository: .build/remote-assets-tests.log and .build/remote-assets-release.log. RelayBar also has .build/remote-assets-helper-tests.log.

## Performance evidence

A generated 4000 × 2250 JPEG was 8,819,363 bytes. Its 512-pixel preview was 13,435 bytes, about 0.15% of the original. Local helper generation took 0.250 seconds in the final full test run. Conditional reuse returned no image bytes. These are synthetic local measurements, not SSH latency or private-host CPU benchmarks.

The 512-folder/10,240-asset in-memory traversal fixture took 0.315 seconds. The 5,000-file local scan took 0.307 seconds. Neither proves large live-host scrolling performance.

## Installed checks

Both app build scripts completed. Developer ID Application: Thought Tides LLC (39HYFR5Z65), hardened runtime and timestamp retained. Strict deep signature verification passed on the installed bundles. Frame retains its sandbox/bookmark/network-client/App Group entitlements. RelayBar retains signed nested Sparkle components and its App Group entitlement.

- Frame arm64 executable SHA-256: add0d2cd7faeeda43a2238c67860a0aabb30e73f940969a44b98443b56e80657.
- RelayBar universal executable SHA-256: 861df1622f112b4189b996e2c63f6159380bf662d681dd7a7b5a3d9ce68486ff.
- RelayBar executable and dSYM UUIDs match: DEBDA188-6995-3CD9-9AC1-B2BBB6B0CF69 (x86_64), 953CAAC3-5E15-323E-A3C3-F1EDA966AD8F (arm64).

Final Frame launched and restored the existing 1,666-asset local library, favorite and current 360-point thumbnail preference. Open… read the installed RelayBar catalog through authenticated v3 IPC and showed exactly the retained comfy, workspace and documentations locations. No host was opened for this check. The chooser was dismissed, leaving the existing library visible.

Prior Frame 0.5.1/7 and RelayBar 1.7.1/13 bundles are preserved under Frame's .build/backups. Intermediate local 0.6.0/8 and 1.8.0/14 bundles are also preserved there. Preferences, catalog and source media were not replaced. RelayBar's menu-only final restart required a normal SIGTERM after its Quit shortcut was unavailable; final bridge connectivity and relaunch were verified.

## Acceptance limits

No private remote source file was moved, restored or downloaded for testing. Real-host Python/Pillow/ffmpeg availability, SSH latency, native first write-consent interaction, complete URL handoff, remote full-screen/batch UI end-to-end, arbitrary network filesystems and every crash/disconnection boundary remain unverified. Remote code rejects missing tools rather than silently downloading originals. Remote moves require same-filesystem hard-link support and suitable permissions. See [current contract](remote-assets.md).

No Git commit, push, PR, notarization submission or public release was made. This is a local signed installation. Existing broad RelayBar release acceptance work is not marked complete.
