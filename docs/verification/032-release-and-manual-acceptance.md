# Task 032 — Release and Manual Acceptance Verification

Updated: 2026-09-29

Result: In progress. VoiceOver inspection is excluded by maintainer decision.
RelayBar 1.6.0 build 11 is the stable release; see
[Task 049 verification](049-relaybar-1.6.0-release.md) for its signed public
artifact and prior-version Sparkle installation evidence. Offline recovery-key
restore, an actual macOS 13 pass, and the remaining scheduled-update,
active-tunnel, and failure matrix remain open.

## Maintainer checklist

### Settings footer

- [x] Open the locally built RelayBar and confirm Settings fits its default
  popover without a scrollbar or overlap.
- [x] Confirm the footer displays `RelayBar 1.4.0 (7)`. Copy it, paste into a
  text field, and confirm the value is exact and the copy icon changes without
  moving adjacent content.
- [x] Open **Website** and **GitHub** and confirm each opens once in the default
  browser at the canonical RelayBar URL.
- [x] With macOS Keyboard navigation enabled, use Tab/Shift-Tab through Back,
  both toggles, Copy, Check for Updates, Website, and GitHub. Activate controls
  with Space or Return and use Escape to return to the tunnel list.
- [x] Enable Reduce Motion, repeat Copy and Check for Updates, and confirm
  feedback does not depend on movement or shift the footer.
- [x] Increase system text size and confirm every Settings control remains
  reachable vertically without horizontal clipping or overlap.
- [x] Confirm **Automatic Updates** uses the promised weekly-check copy,
  persists an intentional toggle change across relaunch, and adds no badge or
  status to the tunnel list. A clean first launch defaults off; an existing
  installation may retain its previous choice. Restore the preferred setting
  after the check.
- [x] Before the production appcast is published, **Check for Updates…** should
  end with the concise retry state. Close and reopen Settings and confirm the
  transient result is gone.

### Profile editor

- [x] Open an existing profile. Confirm Name receives focus without moving the
  form and every section remains evenly inset from both popover edges.
- [x] Open New Profile and confirm the same balanced insets and no horizontal
  scrollbar.
- [x] Add enough forwarding-rule content to scroll vertically. Confirm the
  vertical scrollbar does not shift or clip the form and no horizontal
  scrollbar appears.
- [x] Move focus through visible fields, then verify Cancel preserves the saved
  profile and Save Changes still persists a valid edit.

### Signing and release

- [x] The Keychain account `com.lx2026.RelayBar` public key matches the
  `SUPublicEDKey` embedded in RelayBar.
- [x] Authorize a local Sparkle sign/verify round trip without publishing its
  disposable payload.
- [ ] Export an encrypted offline recovery key to a maintainer-chosen secure
  location and restore-test it in an isolated environment.
- [x] Build, notarize, staple, and Gatekeeper-assess the 1.4.0 build 7 universal
  candidate; verify nested signatures, architectures, dSYM UUIDs, and the
  installed `/Applications/RelayBar.app`.
- [x] After publication approval, publish the verified archive as a GitHub
  prerelease and verify the anonymously downloaded public asset.
- [x] Record the stable signed appcast, a prior-to-newer manual update, and
  Homebrew install/update/uninstall evidence.
- [ ] Record weekly scheduled-update behavior, active-tunnel choices, and
  updater failure cases.

### Minimum supported system

- [ ] On an actual macOS 13 host, repeat the Edit/New/long-scrolled profile
  checks and record the OS/build and screenshots. The structural deployment
  target check alone does not satisfy this item.

## Existing automated evidence

- The strict suite passes 269 tests with 16 expected opt-in skips.
- Fresh light/dark Settings, New/Edit Profile, and scrolled-editor snapshot
  suites pass, including rendered horizontal-containment assertions.
- The RelayBar-target warnings-as-errors universal Release build passes. The
  Developer-ID-signed app, Sparkle nested code, architectures, macOS 13 minimum,
  and executable/dSYM UUIDs verify.
- `plutil`, shell syntax checks, and `git diff --check` pass.

## Evidence log

- 2026-08-02: The maintainer approved notarizing and installing the local
  candidate. The next monotonic identity is RelayBar 1.4.0 build 7; publication
  remains unapproved.
- 2026-08-02: Apple accepted notary submission
  `0406cd1a-4660-4552-a312-7e1f590ee3c7`. Stapler and Gatekeeper accepted the
  universal app; its executable and dSYM UUIDs match for `x86_64` and `arm64`.
  The final ZIP SHA-256 is
  `8a6c622ffea12e87ffc3cf63c2cd0ab60fcde2808febf7e0ac3c83d9fdcddc95`.
  The prior 1.3.0 build 6 app was moved to Trash as a recoverable backup, the
  verified candidate was installed at `/Applications/RelayBar.app`, and the
  installed executable matches the notarized candidate.
- 2026-08-02: The unlocked login Keychain returned the same public EdDSA key
  embedded in `Packaging/Info.plist`. After maintainer authorization, Sparkle's
  `sign_update` signed and verified a disposable local payload. The payload was
  moved to Trash and nothing was published.
- 2026-08-02: The maintainer reported that every Settings-footer and profile-
  editor check above passed on macOS 27.0 build 26A5388g. VoiceOver inspection
  remains waived, and the separate macOS 13 check remains open.
- 2026-08-02: The maintainer approved a beta publication. Commit
  `e260310834b3eeca3cb4a4792846f1bf933edd9e` was tagged
  `v1.4.0-beta.1`; Apple accepted notary submission
  `7106bfde-31d4-4d1f-b965-7eca2f28a181`. The stapled universal archive was
  published as the non-draft GitHub prerelease
  [RelayBar 1.4.0 Beta 1](https://github.com/lx2026/RelayBar/releases/tag/v1.4.0-beta.1).
  Its final `RelayBar.zip` is 6,528,677 bytes with SHA-256
  `358116688d81e9f1c9fe38070cbd4f0dbd7686f0eecb767b1d921bc80661a80a`.
  An anonymous download was byte-identical and passed clean extraction,
  strict signature, stapled-ticket, Gatekeeper, version/build, universal-
  architecture, retained-resource, and launch checks. The stable appcast,
  website download, and Homebrew cask were deliberately left unchanged.
- 2026-08-18: The direct-file correction shipped in the notarized build 8 Beta
  2 artifact from commit `ec78e9e07c1af4ed5254ec36e83a22f1c17bc062`.
  Apple accepted submission `d2157c19-02ff-4195-945a-9f5b3a074c22`. A public
  Beta 1 installed below `/Applications` discovered, installed, and relaunched
  build 8 through the signed public feed; the maintainer confirmed success.
  The live SSH check also opened the exact supplied
  `TRANSCRIPTION_LEARNINGS.md` path and verified bounded Markdown decoding.
  See [Task 034 verification](034-open-direct-remote-file-paths.md).
- 2026-08-18: The exact tested build 8 bytes were promoted as the stable
  [RelayBar 1.4.0 release](https://github.com/lx2026/RelayBar/releases/tag/v1.4.0).
  The ZIP is 6,538,729 bytes with SHA-256
  `292ccadee9e8577c65cac86592778501c51591990a803685c0b71db004e4d105`.
  Its anonymous download is byte-identical and passes version/build,
  universal-architecture, nested strict signature, stapled-ticket,
  Gatekeeper, retained-resource, and executable/dSYM UUID checks.
- 2026-08-18: [PR 22](https://github.com/lx2026/RelayBar/pull/22)
  passed CI and published a freshly signed appcast whose stable enclosure uses
  the already tested ZIP signature. Public Pages deployment
  [32170121350](https://github.com/lx2026/RelayBar/actions/runs/32170121350)
  byte-matches the repository feed and verifies successfully.
- 2026-08-18: [PR 23](https://github.com/lx2026/RelayBar/pull/23)
  passed CI and published the stable README, changelog, security review, and
  website. Pages deployment
  [32170639810](https://github.com/lx2026/RelayBar/actions/runs/32170639810)
  presents both stable download links at 1440 × 900 and 390 × 844 with no
  horizontal overflow, missing images, or browser warnings.
- 2026-08-18: The maintainer tap merged
  [Homebrew PR 1](https://github.com/lx2026/homebrew-tap/pull/1) at
  `fc5fd2c31cfa2ae3005488b6a44d65071b4a57d0`. Homebrew style and livecheck
  passed, and the current strict online/download/signing auditor returned zero
  findings. A real cask upgrade replaced the 1.3.0 receipt with 1.4.0 build 8.
  The installed universal app passed strict signature, stapler, and Gatekeeper
  checks and launched. Uninstall removed the managed app while leaving the
  preferences checksum and all 54 application-support files unchanged; a
  clean install restored and relaunched the same stable app. The cask does not
  declare `auto_updates` because its in-app path has not been certified from a
  Homebrew-managed prior build.
- 2026-08-25: The exact notarized build 9 bytes from implementation commit
  `f9026fe9e58eda92b3c1d451fd54a2229b3699b1` were published as the official
  [RelayBar 1.5.0 release](https://github.com/lx2026/RelayBar/releases/tag/v1.5.0).
  Apple accepted notary submission `ea496e01-26d1-45be-bf8d-791757062bd7`.
  The universal ZIP is 6,757,777 bytes with SHA-256
  `fa292463fb2336de3f93d1fec1d18ddea5088c51151c871cdf0323cde43be8ae`;
  an anonymous download was byte-identical and passed clean extraction,
  version/build, architecture, nested strict-signature, stapled-ticket,
  Gatekeeper, minimum-system, notices, and executable checks.
- 2026-08-25: [PR 25](https://github.com/lx2026/RelayBar/pull/25)
  passed CI and published the signed build 9 appcast. Public Pages deployment
  [32920339180](https://github.com/lx2026/RelayBar/actions/runs/32920339180)
  byte-matches the repository feed and verifies both retained signed
  enclosures. The maintainer explicitly waived the prior-build updater
  rehearsal for the 1.5.0 release.
- 2026-08-25: [PR 26](https://github.com/lx2026/RelayBar/pull/26)
  passed CI and published concise 1.5.0 README, changelog, security review, and
  website updates with privacy-safe screenshots rendered from the shipped UI.
  Pages deployment
  [32920761126](https://github.com/lx2026/RelayBar/actions/runs/32920761126)
  presents the stable links and images without horizontal overflow or browser
  errors at 1440 × 900 and 390 × 844; both public images byte-match the
  committed assets.
- 2026-08-25: The maintainer tap merged
  [Homebrew PR 2](https://github.com/lx2026/homebrew-tap/pull/2) at
  `ff889de81dcd8f64a36b9e830e17c98a01023ef8`. Ruby syntax, Homebrew style,
  and livecheck passed. A fresh install, launch, uninstall, and reinstall
  produced RelayBar 1.5.0 build 9 with the verified executable SHA-256
  `5f3d8a4f751752fe8a7db36fc18cbac18cc6ecccd4d36288864e22d3602cca73`;
  strict signature, stapler, and Gatekeeper checks passed. Uninstall removed
  the managed app while leaving the preferences checksum and all 276
  application-support files unchanged. The final Homebrew-managed app is
  installed and running. Homebrew's strict online audit could not start cask
  inspection because Homebrew 6.0.19 requires Xcode 27 while this Mac has
  Xcode 26.6; no audit finding against the cask was produced.
