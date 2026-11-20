# Build and Release

## Requirements

- macOS 13 or newer
- Full Xcode with Swift 6.2 or newer and the macOS SDK
- macOS 14 or newer for Frame
- Developer ID Application certificate for packaged builds
- Sparkle's EdDSA private key in the login Keychain under account
  `com.lx2026.RelayBar`

On the maintainer's current Mac, the saved notarization profile is `AC_NOTARY`.
Use `NOTARY_PROFILE=AC_NOTARY ./scripts/notarize-release.sh`. Confirm access
with `xcrun notarytool history --keychain-profile AC_NOTARY`; this profile's
history includes the accepted RelayBar 1.5.1 submission. The profile name is
configuration, while its credentials remain in Keychain. Sparkle's
`com.lx2026.RelayBar` account is a separate update-signing key.

## Commands

- `./scripts/test.sh` runs shared-package and both app suites; pass `relaybar`, `frame`, or `shared` to select one.
- `./scripts/build-app.sh` builds and signs `.build/RelayBar.app`.
- `./Apps/Frame/Scripts/build-app.sh release` builds and signs `Apps/Frame/.build/app/Frame.app` for Apple silicon. Both `release` and `debug` check that `lipo -archs` reports exactly `arm64` before packaging.
- `./scripts/package-release.sh [relaybar|frame]` creates `.build/RelayBar.zip` or `.build/Frame.zip`; omission selects RelayBar.
- `./scripts/notarize-release.sh [relaybar|frame]` builds the selected app, submits its archive, requires an Accepted result, staples, rebuilds the ZIP and validates a clean extraction. Omission selects RelayBar. Submission JSON is retained as `.build/notarization-<app>.json`.
- `./scripts/update-appcast.sh <final ZIP> <immutable HTTPS URL>` first checks
  a clean extraction of the archive: a strict deep signature that satisfies
  the bridge's requirement for RelayBar (Apple anchor, the bundle identifier
  from the production Info.plist, and the Developer ID team that prefixes the
  App Group in `RelayBar.entitlements`), the stapled ticket, Gatekeeper, and
  RelayBar's identity, version and build through `release-plan.py`. It then
  requires the archive's `SUFeedURL` and `SUPublicEDKey` and the signing
  account's public key to match the production Info.plist, verifies the
  published archive byte-for-byte, preserves full-update history, and signs
  the appcast in a staging directory. Only after the production-feed verifier
  accepts the staged feed does it copy the feed beside `docs/appcast.xml` and
  rename it into place.
- `./scripts/verify-update-feed.sh` downloads and verifies every retained full
  update enclosure against its declared length and EdDSA signature.
- `./scripts/stage-private-update.sh <final ZIP> <port> <new directory>` creates
  a one-build signed appcast and byte-identical archive for a private loopback
  rehearsal without reading or changing the production appcast.
- `./scripts/verify-private-update-feed.sh <appcast> <ZIP> <port>` requires one
  loopback enclosure, the embedded/keychain EdDSA key match, the declared byte
  length, a positive build number, and valid feed and archive signatures.

RelayBar source and its Xcode project live in `Apps/RelayBar`; Frame lives in `Apps/Frame`. Shared contracts are local Swift package dependencies under `Packages/AppComposition`. Root distribution commands and public Pages/feed paths are unchanged.

Frame's app bundle is assembled by `Apps/Frame/Scripts/build-app.sh`. Since Task 063 it calls `bundle-renderer-resources.sh`, which copies the Markdown renderer's two SwiftPM resource bundles (the highlighter and SwiftMath's fonts) into `Contents/Resources`, prunes them to the `github` themes and the Latin Modern font as RelayBar's Xcode build phase does, removes the build's own seal from each so that the app's signature covers their files, adds their licence texts, and fails if a bundle or a required file is missing. The generated resource lookup finds a bundle only inside the app, so one left out would stop Frame the first time it highlights code or typesets math.

Distribution commands require explicit approval for the selected release. After that approval, set `RELAYBAR_PUBLICATION_APPROVED=yes` and `NOTARY_PROFILE=AC_NOTARY` for the notarization invocation. The existing approval-variable name applies to both apps. Unknown app names and extra arguments fail before building. The script stops on a failed submission or any status other than Accepted; it never staples a rejected submission. Final verification covers strict signatures, stapled tickets and Gatekeeper on both the original bundle and a clean extraction, then archive identity/version/build and SHA-256 through `release-plan.py`. Local workflow tests substitute Apple tools and do not submit anything.

CI selects an installed full Xcode with Swift 6.2 or newer using `scripts/select-ci-xcode.sh`, tests the three apps and both shared packages, explicitly builds the Frame executable, and builds RelayBar's unsigned Release Xcode target. Selection is job-local through `DEVELOPER_DIR`; it does not change the machine's global Xcode selection.

The Xcode target pins Sparkle 2.9.4 exactly. SwiftPM deliberately omits it so
unit tests cannot initialize an updater or contact the network. The application
property list fixes the stable HTTPS feed, public EdDSA key, seven-day interval,
automatic checks off by default, and automatic downloads/installs disabled.
It also requires a signed feed and verification before extraction. The updater
delegate sends no system-profile fields.

Private update staging is deliberately separate from production publication.
Its appcast may use only `http://127.0.0.1:<explicit-port>/RelayBar.zip`, is
served from a new local directory, and is selected by the guarded maintainer
launch argument described in the application-shell specification. It never edits
`docs/appcast.xml`, accepts a network host, or weakens production HTTPS and
signature requirements. Launch the prior build with `open --args
--maintainer-update-feed http://127.0.0.1:<port>/appcast.xml`; stop the loopback
server when the rehearsal ends.

The Xcode target prunes unused renderer resources from the generated app bundle. It retains Highlighter's formatter and the two themes RelayBar selects, plus SwiftMath's default Latin Modern font, metrics, and bundled font licenses. It removes the other highlight themes, alternate math fonts, and SwiftMath's package-development conversion script. Source dependencies remain unchanged and every clean build reproduces the same pruning step.

Release builds generate a dSYM and then apply non-global symbol stripping to the installed executable. Debug builds remain unstripped. The dSYM and executable UUIDs must match before a release artifact is accepted.

The app is distributed outside the Mac App Store, uses the hardened runtime, and is intentionally not sandboxed.

## Stable GitHub release

Public pre-releases on 2026-11-17: **RelayBar 2.0.0 Beta 1, build 26**, published as `v2.0.0-beta.1` with `RelayBar.zip`, and **Frame 2.0.0 Beta 1, build 20**, published as `frame-v2.0.0-beta.1` with `Frame.zip`. Both tags are annotated and point at `5ca8d77`, the commit the archives were built from. Frame was published and checked first, and an anonymous download of each asset equals the verified archive byte for byte. Neither is the repository's latest release: `v1.6.0` remains stable, and the Sparkle feed, `docs/appcast.xml` and the Homebrew cask were not changed, so a 1.6.0 installation is not offered the beta. The owner asked for the beta ahead of native and live-host acceptance, which stays open. See [Task 071 verification](../../verification/071-2.0.0-beta-1-pre-releases.md).

On 2026-11-20, notarized universal RelayBar 2.0.0 (31) replaced build 30 on the maintainer's Mac. To launch the installed copy in the background, use `open -g /Applications/RelayBar.app`. The additional `-j` flag requests a hidden launch. [Build 31 verification](../../verification/067-switchboard-popover-settings-window-icon.md#local-installation-build-31)

The earlier installation that day paired universal RelayBar 2.0.0 (30) with Apple-silicon Frame 2.0.0 (27). The paired iPad has the development-signed mobile app 1.0.0 (2). [Verification](../../verification/088-089-ux-parity.md#november-20-reliability-and-interaction-checks)

Local installation on 2026-11-17: **RelayBar 2.0.0, build 26** and **Frame 2.0.0, build 20**, both built from commit `5ca8d77`: merged Tasks 050–070 with only the build numbers raised. Both are universal, Developer ID signed, **notarized and stapled**, passed Gatekeeper after replacement in Applications, and completed launch. They are the archives prepared for the 2.0.0 Beta 1 pre-releases; see [Task 071 verification](../../verification/071-2.0.0-beta-1-pre-releases.md). Builds 25 and 19, from commit `3d140fa` (Tasks 067–069), were installed earlier the same day and are backed up, as are RelayBar build 24 and Frame build 17 before them. The commit ids in these records are those of the pushed history: builds 25 and 19 were made just before a documentation-only edit of the then unpushed commits, from identical application sources. Frame build 19 was installed without a catalog backup, by the owner's decision, because the catalog lives in the shared App Group container, which the installing session cannot read. Frame 2.0.0, build 18, was notarized on 2026-11-16 and never installed. The initial bundle ID change gave Frame a fresh sandbox container; later installations retain it. Native interaction and live-host acceptance remain open. See [RelayBar build 25 evidence](../../verification/067-switchboard-popover-settings-window-icon.md#local-installation-build-25), [Frame build 19](../../verification/068-frame-reader-layout.md#local-installation-build-19) and [2.0.0 installation evidence](../../verification/066-local-notarized-install.md#200-follow-up); earlier installations are recorded in the same records and under [Task 063](../../verification/063-one-markdown-renderer.md#local-installation).

Local-only update on 2026-10-23: **1.6.0, build 17**, paired with Frame **0.1.0, build 11**, uses bridge v5 for batch deletion and arbitrary companion groups. Frame adds session-only temporary cache, native remote video playback, favorite-and-next and smoother review. Permanent Delete remains immediate, Archive/Restore separate and Frame navigation history-neutral. Both signed apps are installed in Applications; they are **not notarized or published**. Release versions and public channels are unchanged. App Group and nested Sparkle signing boundaries are retained. See [Task 055](../../task-specs/archive/055-frame-batch-delete.md); prior deliveries remain in [Task 053](../../verification/053-frame-direct-delete.md), [Task 051](../../verification/051-explicit-frame-history.md) and [Task 050](../../verification/050-frame-viewer-local-install.md).

The current stable release is **1.6.0, build 11**, published as `v1.6.0` with
one immutable `RelayBar.zip`. GitHub, the signed Sparkle feed, the website,
and the maintainer Homebrew cask use that artifact. See
[Task 049 verification](../../verification/049-relaybar-1.6.0-release.md) for
the source commit, final checksum, notarization, and update/install evidence.

Task 058's local refactor staging retains RelayBar 1.6.0/20 and Frame 0.1.0/15.
Separate signed archives, a clean universal RelayBar build and an isolated
prior-build Sparkle update have passed. The archives are not notarized for
distribution and have not replaced the Applications bundles or any public
artifact. Homebrew upgrade/relaunch and final native acceptance remain open;
see [Task 058 verification](../../verification/058-composable-app-architecture.md).

A stable release starts from a clean commit with consistent marketing version,
monotonic build number, bundle identifier, and deployment target. Any
post-freeze application change requires a new build number and a complete
rebuild and notarization.

Before tagging, run the complete tests, a warnings-as-errors Release
build, property-list and license checks, resource-pruning checks, executable
and dSYM UUID comparison, and `git diff --check`.

`./scripts/notarize-release.sh` submits the pre-staple archive, waits for Apple,
staples and validates the app, then replaces the submitted ZIP with a final
archive containing the stapled app. Compute the published SHA-256 only after
that final rebuild. Verify the final ZIP through clean extraction, the supported
architectures (arm64 for Frame, arm64 and x86_64 for RelayBar), version and
build, timestamped hardened-runtime signature,
stapled ticket, Gatekeeper, bundled notices and resources, and launch.

`build-app.sh` re-signs Sparkle's Installer and Downloader XPC services,
Autoupdate tool, Updater app, and framework inside-out before signing RelayBar.
Every nested boundary and the final bundle must pass strict code-signature
verification. Appcast generation accepts only the final archive rebuilt after
stapling; never sign a pre-notarization or pre-staple ZIP. `update-appcast.sh`
refuses an archive without a valid stapled ticket, from another team, or with
other updater settings, and a signing key that differs from `SUPublicEDKey`,
before Sparkle signs anything. Script tests with stand-in tools cover those
refusals and an unchanged `docs/appcast.xml` after a failed feed verification
or a failed copy. Production
verification checks the feed signature before downloading and validating every
retained enclosure.

Create an annotated version tag on the verified release commit. A stable GitHub
release contains one immutable `RelayBar.zip`, is neither a draft nor a
prerelease, and must not have its asset replaced in place. Independently
download the public asset without repository credentials, compare its SHA-256
and bytes with the verified local archive, and repeat signature, ticket,
Gatekeeper, metadata, and architecture checks before updating public links or
the Homebrew cask.

Publication order is strict:

1. verify, notarize, staple, and rebuild the final ZIP;
2. create the immutable stable GitHub release asset and independently compare
   it byte-for-byte with the final ZIP;
3. run `update-appcast.sh` against that public URL, review the retained entries,
   and publish the signed `docs/appcast.xml`;
4. verify the public feed and complete a prior-build update before changing
   website claims or the Homebrew cask; and
5. update Homebrew to the same URL and SHA-256, then repeat install, update,
   signature, Gatekeeper, and uninstall checks.

Build numbers in the appcast are monotonic. Published assets and feed entries
are immutable; corrections use a higher build and a newly notarized archive.
Release notes, direct download, appcast enclosure, and cask must resolve to the
same version and bytes.

RelayBar 1.3.0 and older have no updater. The first Sparkle-enabled release is
a manual bridge advertised through the website, GitHub release, and Homebrew;
only that release and newer can use the in-app path.

### Update-signing key custody and recovery

The private EdDSA key stays in the maintainer's login Keychain under account
`com.lx2026.RelayBar`; only its public key is committed. Before publishing the
first update, export one encrypted offline recovery copy with Sparkle's
`generate_keys --account com.lx2026.RelayBar -x <secure-path>`, verify a restore
on an isolated maintainer environment, and record its custodian without putting
the path, key, or Keychain password in the repository or CI logs.

If the EdDSA key is lost but uncompromised, restore that backup. If it is
suspected compromised, stop appcast publication immediately, generate a new
key, and ship a higher build that embeds and signs with the new key while
retaining the same valid Developer ID identity; Sparkle's code-signing
continuity establishes the rotation. If both trust paths are compromised,
disable the feed and require a manually downloaded notarized recovery build.
Never remove an EdDSA key from a build that already participates in the update
chain.

## Frame and paired releases

Frame's current public pre-release is **2.0.0 Beta 3, build 23**, for macOS 14 or later on Apple silicon and Intel. It updates by manual download and pairs with RelayBar 2.0.0 Beta 3 for remote libraries. Frame uses a separate annotated tag and an immutable `Frame.zip` asset in the shared repository. The beta is published with `make_latest` false. See the [release](https://github.com/lx2026/RelayBar/releases/tag/frame-v2.0.0-beta.3) and [verification record](../../verification/075-frame-2.0.0-beta-3.md).

Beta 3 is the last Intel-compatible Frame release. Starting with build 24, run Frame QA natively on Apple silicon and verify that the executable extracted from `Frame.zip` reports exactly `arm64` and matches the arm64 dSYM UUID. The minimum macOS version is 14.0.

For the next paired rollout, finish native and live-host acceptance, choose explicitly approved release versions and monotonic builds, freeze a clean commit, and notarize each app separately. Publish and independently verify Frame's archive before publishing RelayBar's archive and advancing its Sparkle feed. The companion download must be available before a RelayBar update can expose an incompatible pairing. Follow the existing RelayBar feed, prior-build rehearsal, website and Homebrew order above. Release notes must name the compatible pair and explain that Frame updates manually; bridge v7 rejects older peers. No new version or public URL is selected by these preparation scripts.

## Homebrew cask

The maintainer-owned `lx2026/homebrew-tap` repository publishes
`Casks/relaybar.rb`. The cask installs the same immutable, versioned
`RelayBar.zip` attached to the stable GitHub release and pins its SHA-256. It
uses the standard `app "RelayBar.app"` artifact plus
`uninstall quit: "com.lx2026.RelayBar"`, declares the real macOS minimum, and
does not bypass quarantine, re-sign the bundle, run custom lifecycle scripts,
or remove RelayBar user data. During an upgrade, Homebrew quits and records a
running registered RelayBar, replaces and registers the bundle, then reopens
only that successfully quit app. An initially stopped app stays stopped, and
`brew upgrade --cask --no-quit` remains an explicit user override. Homebrew
captures uninstall artifacts in the receipt at install time; changing the tap
does not retrofit a legacy receipt, so an installation made before the quit
directive needs one reinstall or a manual quit for its first later upgrade.

After publishing and independently verifying a stable release:

1. update the cask version and SHA-256 to that exact release archive;
2. confirm its URL, homepage, macOS requirement, and app artifact;
3. run Homebrew style plus strict online and signing audits;
4. test install, launch, version, Gatekeeper, running-app upgrade/relaunch,
   stopped-app upgrade, and uninstall behavior; and
5. confirm the extracted archive and cask installation contain the same signed
   application.

The cask must not declare `auto_updates true` until a Homebrew-installed
Sparkle-enabled build passes the complete in-app flow. Until then users update
with `brew upgrade --cask lx2026/tap/relaybar`. Once enabled, the cask still
pins and audits the same immutable stable archive; the updater never invokes
Homebrew or guesses the installation source.

## Project Website

The GitHub Pages site is a build-free static site under `docs/`. Its
`index.html`, `styles.css`, and local image assets are sufficient to render the
page; it does not require a generated page runtime or third-party font request.
The primary download and the Homebrew command stay on stable 1.6.0 and name it
explicitly; beta links name 2.0.0 Beta 1.

The page has five parts. The hero draws a strip of the menu bar with the RelayBar popover hanging from it, beside the headline, the stable download and a link to the beta. Three short facts follow, then Remote Files, then a dark band for Frame with its beta download, then one Download list with a row each for RelayBar 1.6.0, RelayBar 2.0.0 Beta 1 and Frame 2.0.0 Beta 1. The list and the two sentences around it carry everything about the beta: the downloads from the GitHub pre-releases (`v2.0.0-beta.1`, `frame-v2.0.0-beta.1`) and their release notes, the minimum macOS versions, that the two betas work together and an older RelayBar is refused, that Frame updates manually, and that Homebrew and RelayBar's in-app updater stay on 1.6.0. Colours are the apps' paper palette in light and dark, and the popover picture follows the colour scheme; text is the system font, with no script. Screenshots show the 2.0 beta with sample data, and the page says so. Both READMEs separate stable 1.6.0 from the 2.0.0 beta, link both pre-releases, document bridge compatibility and plugin defaults, and separate Markdown's restrictions from online HTML previews.

## iPhone and iPad development

The mobile target uses `Apps/RelayBarMobile/App/Version.xcconfig` for both build configurations. From the repository root, build it against the installed iOS Simulator SDK without launching a device:

```sh
xcodebuild -project Apps/RelayBarMobile/RelayBarMobile.xcodeproj -scheme RelayBarMobile \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/mobile-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Run `./scripts/test.sh mobile`, `./scripts/test.sh transport` and `./scripts/test.sh shared` on the Mac. The transport tests bind chosen port numbers on the one loopback port space, so the script runs that suite one test at a time. Generate the off-screen phone and iPad gallery with `swift run --package-path Apps/RelayBarMobile ScreenGallery .build/screens`. Record physical-device results in the [mobile checklist](../../verification/mobile-device-checklist.md).

The `RelayBarMobileUITests` scheme exercises search, rotation and hidden-file controls with the in-process demo host. Set `IPAD_SIMULATOR_UDID` to an existing compatible iPad from `xcrun simctl list devices available`. This command runs the test on that device without cloning it.

```sh
xcodebuild -project Apps/RelayBarMobile/RelayBarMobile.xcodeproj -scheme RelayBarMobileUITests \
  -destination "platform=iOS Simulator,id=${IPAD_SIMULATOR_UDID}" -parallel-testing-enabled NO test
```

Preview the archive step with `./scripts/archive-mobile.sh --dry-run`. For a signed archive, the maintainer supplies the confirmed boolean encryption declaration in the app’s Info.plist, sets `DEVELOPMENT_TEAM` and installs the appropriate local signing assets. Run `./scripts/archive-mobile.sh` to create `.build/RelayBarMobile.xcarchive`. Export, upload, TestFlight distribution and App Store publication require explicit maintainer approval. [Export compliance](../../release/mobile/export-compliance.md)
