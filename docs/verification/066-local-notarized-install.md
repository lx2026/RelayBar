# Local notarized installation — 2026-11-16

Latest installed pair: **RelayBar 2.0.0 (22)** and **Frame 2.0.0 (17)**, following explicit version approval; see [2.0.0 follow-up](#200-follow-up). The initial installation below is retained as history. RelayBar was later replaced by 2.0.0 (23) and then 2.0.0 (24); see [Task 067](067-switchboard-popover-settings-window-icon.md#local-installation-build-24). Frame 2.0.0 (18) is notarized but not installed, so Frame 2.0.0 (17) remains; see [Task 068](068-frame-reader-layout.md#local-installation-build-18).

The user requested notarization and replacement of both Applications bundles for personal testing. Source was the clean commit `a896188675ea8b1ef876e552a2fdd0cb22b9882d` on `codex/task-058-composition`. After fetching, the branch had no upstream and was two commits ahead, zero behind `origin/main`, based on `5ebcfddcc8f3d494a2df63aa7e70b1f35083f4bf`. Application source, versions and build numbers were unchanged.

| App | Installed version | Bundle ID | Architectures |
| --- | --- | --- | --- |
| RelayBar | 1.6.0 (21) | `com.lx2026.RelayBar` | arm64, x86_64 |
| Frame | 0.1.0 (16) | `com.lx2026.Frame` | arm64, x86_64 |

Both Release builds used the repository's packaging and notarization scripts, Developer ID team `39HYFR5Z65`, and Keychain profile `AC_NOTARY`. Apple initially returned HTTP 403 for an unsigned or expired agreement. After the user accepted the agreement, access recovered and both submissions were accepted with status code 0 and no issues:

- RelayBar: `abfc9e40-6a13-407a-9a20-e33f4e71c8fa`.
- Frame: `010f5482-d7a3-4d3e-9dd2-3c65af37285f`.

Final ZIP SHA-256 values, computed after stapling:

- RelayBar: `6baa8b21264847e9635c634ae441ab1976549cbce152d643deabc911b3955d3e`.
- Frame: `16cd9cfc24764e7937fa70ce21d4ffbf001aa2ab8cfe40f1cf68a83249ea4f08`.

## Verification and installation

Clean extractions and the installed bundles passed strict deep signature verification, timestamped hardened-runtime identity checks, stapled-ticket validation, and Gatekeeper assessment as Notarized Developer ID. Both architectures, source metadata and minimum OS matched; executable/dSYM UUIDs matched for both slices. The shared App Group, Frame's sandbox entitlements, renderer bundles, two GitHub themes, Latin Modern font/metrics, resource pruning and bundled notices/licenses were verified.

The previous apps quit normally. The verified pair replaced `/Applications/RelayBar.app` and `/Applications/Frame.app`; installed executable hashes match the clean extractions. Launch Services resolves both current bundle IDs to those Applications paths, and both processes completed launch. RelayBar was observed as PID 70393 and Frame as PID 70396.

Prior app archives were clean-extracted and signature-verified before replacement. They remain in `.build/local-notarized-install-2026-11-16/backups/` as `RelayBar-1.6.0-build21.zip` and `Frame-0.1.0-build16-old-bundle-id.zip`. Preferences and user data were not removed or migrated. The sandbox container of Frame's previous bundle ID remains intact; its new bundle ID starts with fresh settings and library state.

Logs, Apple's submission records, final archives and checksums, dSYM archives, extracted/installed verification JSON and launch evidence are retained in `.build/local-notarized-install-2026-11-16/`.

The existing [final-tree test gate](066-interface-polish.md#checks) remains applicable: application source did not change, so suites were not rerun. Fresh Release packaging and signing passed for both apps. `git diff --check` passed after recording this installation.

## Remaining acceptance

Native interaction, the remaining design-pair review, first-use rendering and live-SSH workflows are for the user's hand test. Launch and packaging checks do not certify those flows. Tasks 065 and 066 remain open. No commit, push, tag, GitHub release, feed, website or Homebrew publication occurred.

## 2.0.0 follow-up

The user explicitly approved **2.0.0 for both apps**. Both source property lists now use that version, with RelayBar build **22** and Frame build **17**; both RelayBar Xcode configurations match. No application logic changed. The build source is commit `a896188` plus the uncommitted version/build metadata patch, retained as `application-source.patch` with SHA-256 `43390167d21d7b5b52ab79811616600e9165a762a5b24b3cce487307c82800e6`. After fetching, the feature branch remained two commits ahead and zero behind `origin/main`. No commit or push was requested or performed.

Both rebuilt apps were notarized using `AC_NOTARY` and team `39HYFR5Z65`. Apple's logs report Accepted, status code 0 and no issues:

| App | Submission | Final ZIP SHA-256 |
| --- | --- | --- |
| RelayBar 2.0.0 (22) | `6cf915c0-527e-458e-92fe-5f59d8829903` | `03fae5ac4520e0f78713a1b2098b7c22acffe420670a2201163e543e6c4be400` |
| Frame 2.0.0 (17) | `f6d938c3-2c8c-42e6-8a1a-50a90b5778cd` | `5443b7a722bcdd20552d9fae67d27f6b076bc7d4e5538a819b6d36af219e240d` |

All extraction and installed-bundle checks described above passed again, including both architectures, matching dSYM UUIDs, exact 2.0.0 version/build metadata, signatures, entitlements, resources, stapled tickets and Gatekeeper. The application metadata patch remained unchanged throughout building and installation. Nine release-script tests, property-list/project lint and `git diff --check` passed. Application logic suites were not rerun for this metadata-only change.

The prior notarized pair quit normally, was backed up and was replaced in Applications. Installed binaries match the verified archives. Both new apps completed launch and Launch Services resolves their bundle IDs to Applications: RelayBar PID 72732, Frame PID 72735. No preferences, library data or permissions were removed or migrated; this follow-up retains the same bundle IDs as the initial installation.

Evidence and final artifacts are in `.build/local-notarized-install-2.0.0-2026-11-16/`. Recoverable previous apps are `backups/RelayBar-1.6.0-build21.zip` and `backups/Frame-0.1.0-build16.zip` beneath it; both backup archives were clean-extracted and signature-verified. Earlier pre-rename Frame backups remain in the initial installation directory.

Both apps are ready for the user's hand test. Native and live-host acceptance remains open. Version metadata and documentation changes remain uncommitted; no public release, tag, feed, website or Homebrew change occurred.
