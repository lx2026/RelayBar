# Task 049 — RelayBar 1.6.0 Release Verification

Verified: 2026-09-29

Result: Pass. RelayBar 1.6.0 build 11 is the stable GitHub release, signed
Sparkle update, website download, and Homebrew cask. The final notarized app
is installed and running at `/Applications/RelayBar.app`.

## Source and checks

- Release source: `4f8a8f428deb3c420c0fee4bb87e879beeea4b4c` on
  `codex/ssh-retry-settings`; annotated `v1.6.0` resolves to that commit.
  It includes accepted Tasks 040–048. Preparation began from fetched
  `origin/main` at `1cc8c45815addd687ff330f89e9eac99505b1249`, with zero
  divergence. Subsequent changes concern publication and documentation only.
- `swift test -Xswiftc -warnings-as-errors`: 328 tests, 21 expected opt-in skips,
  307 passed, no failures. Existing Tasks 045–048 visual evidence applies to the
  unchanged application source. The Task 037 workspace matrix was also
  recaptured successfully for current website screenshots.
- Universal Release build passed the app target's warnings-as-errors and
  complete strict-concurrency settings. Property-list lint, shell syntax,
  resource pruning, bundled notices/font licenses, and `git diff --check` pass.
- Executable/dSYM UUIDs match: `x86_64` is
  `2E4CDE64-1C3B-3B02-A89E-CC17AB5FC721`; `arm64` is
  `C25008E9-5C4D-3ED4-9B90-A94810D4EAA1`.
- Main CI [36526858252](https://github.com/lx2026/RelayBar/actions/runs/36526858252)
  and [36527265326](https://github.com/lx2026/RelayBar/actions/runs/36527265326)
  pass package tests and the unsigned macOS Release build.

## Immutable artifact and channels

- Apple accepted notarization `a401da54-8135-4a1a-ad3d-5dc0ecada352` using the
  existing `AC_NOTARY` profile. Stapling and ticket validation pass.
- Final `RelayBar.zip`: **6,897,850 bytes**; SHA-256
  `7c9415c51fd80fe3174aa43198713d79003c92d3b3a6262bbdd7e265911168aa`.
- Clean extraction verifies version 1.6.0, build 11, bundle identifier
  `com.lx2026.RelayBar`, macOS 13 minimum, and both architectures. Deep strict
  signature verification, timestamped hardened runtime, team `39HYFR5Z65`,
  ticket validation, and Gatekeeper `Notarized Developer ID` all pass.
- The [stable release](https://github.com/lx2026/RelayBar/releases/tag/v1.6.0)
  is non-draft and non-prerelease with one immutable `RelayBar.zip`. An anonymous
  public download is byte-identical and independently passes the same signature,
  ticket, Gatekeeper, metadata, and architecture checks.
- Feed commit `2f5c3aa` is published on both the feature branch and `main`.
  The live appcast byte-matches the source and verifies all four retained signed
  enclosures. The new enclosure uses build 11 and the exact final archive length.
- Website commit `8fe1217` publishes both 1.6.0 download links and release notes.
  Pages deployments `36526857314` and `36527264533` succeeded. Desktop
  1440 × 900 and mobile 390 × 844 browser checks found no horizontal overflow,
  missing images, browser error, or console warning. Lazy-loaded images were
  explicitly loaded and checked. Current app fixtures supply the refreshed
  tunnel, profile, workspace, and preview screenshots.

## Prior-version update

The official public 1.5.1 archive was extracted to an isolated rehearsal
location. Sparkle's official CLI was built from the pinned 2.9.4 source and
used the same signed framework as the release. The local helper's deployment
target was set to macOS 13 for compatibility with Xcode 27; this did not modify
RelayBar or its release artifact.

A probe found the update, and a real immediate update through the production
HTTPS feed completed download, extraction, and installation. The resulting
app is 1.6.0 build 11 and its executable byte-matches the release. Signature,
stapled ticket, and Gatekeeper checks pass afterward.

The native computer-use inspection tool timed out, so this is CLI-driven
Sparkle installation evidence, not a claimed manual GUI update. The wider
active-tunnel, scheduled-update, failure, recovery-key, and actual-macOS-13
matrix remains open in Task 032. No live production deletion was performed.

## Homebrew and installed app

- Tap commit `5ce35ea` was pushed on `codex/relaybar-1.6.0` and fast-forwarded
  to tap `main`. It pins the same version, immutable URL, and checksum while
  retaining `uninstall quit: "com.lx2026.RelayBar"` and no `auto_updates` stanza.
- Ruby syntax, Homebrew style, strict online/signing audit, and livecheck pass.
  Livecheck reports 1.6.0 as current. Homebrew only warns that its explicit
  signing-audit flag is deprecated and macOS 27 is prerelease.
- Real running-app upgrade: official 1.5.1 PID 51095 quit through Homebrew,
  the cask installed 1.6.0, and exactly one new app reopened as PID 51234.
- Uninstall removed the app and stopped the process while preserving all 282
  files under `~/Library/Application Support/RelayBar`. Clean reinstall left
  the app stopped until explicit launch; the final app runs as PID 51674.
- Product preferences remained at SHA-256
  `4e7970a125114872434fba0b0b6a10737df3a24bd6c2de06b4875edc726a1585`.
  The comparison excludes Sparkle timing and AppKit window-state keys.
  All 282 support-file hashes also remain unchanged after reinstall.
- Installed executable matches the notarized archive; deep strict signature,
  stapled ticket, and Gatekeeper checks pass. The preceding local review app
  remains recoverable at `.build/RelayBar-before-1.6.0-release.app`.

## Local release guidance

The existing local `AC_NOTARY` setup is now recorded in the repository release
guide, linked from `AGENTS.md` and README. The requested reusable `macos-release`
skill is installed in the maintainer's personal skills directory with automatic
discovery enabled; skill validation passes. It records the profile and team,
separates Sparkle signing, and points to project-specific channel instructions.
It contains no credentials or private keys.

Reproducible local logs and captures are under `/tmp/relaybar-049-*`, with final
and public extracted archives plus the update rehearsal under `.build/Task049/`.
