# Build and Release

## Requirements

- macOS 13 or newer
- Xcode command-line tools
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

- `swift test` runs the package tests.
- `./scripts/build-app.sh` builds and signs `.build/RelayBar.app`.
- `./scripts/package-release.sh` creates `.build/RelayBar.zip`.
- `./scripts/notarize-release.sh` submits, waits, staples, and validates a release.
- `./scripts/update-appcast.sh <final ZIP> <immutable HTTPS URL>` verifies the
  published archive byte-for-byte, preserves full-update history, signs the
  appcast, and runs the production-feed verifier.
- `./scripts/verify-update-feed.sh` downloads and verifies every retained full
  update enclosure against its declared length and EdDSA signature.
- `./scripts/stage-private-update.sh <final ZIP> <port> <new directory>` creates
  a one-build signed appcast and byte-identical archive for a private loopback
  rehearsal without reading or changing the production appcast.
- `./scripts/verify-private-update-feed.sh <appcast> <ZIP> <port>` requires one
  loopback enclosure, the embedded/keychain EdDSA key match, the declared byte
  length, a positive build number, and valid feed and archive signatures.

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

The current stable release is **1.6.0, build 11**, published as `v1.6.0` with
one immutable `RelayBar.zip`. GitHub, the signed Sparkle feed, the website,
and the maintainer Homebrew cask use that artifact. See
[Task 049 verification](../../verification/049-relaybar-1.6.0-release.md) for
the source commit, final checksum, notarization, and update/install evidence.

A stable release starts from a clean commit with consistent marketing version,
monotonic build number, bundle identifier, and deployment target. Any
post-freeze application change requires a new build number and a complete
rebuild and notarization.

Before tagging, run the complete tests, warnings-as-errors universal Release
build, property-list and license checks, resource-pruning checks, executable
and dSYM UUID comparison, and `git diff --check`.

`./scripts/notarize-release.sh` submits the pre-staple archive, waits for Apple,
staples and validates the app, then replaces the submitted ZIP with a final
archive containing the stapled app. Compute the published SHA-256 only after
that final rebuild. Verify the final ZIP through clean extraction, both
architectures, version and build, timestamped hardened-runtime signature,
stapled ticket, Gatekeeper, bundled notices and resources, and launch.

`build-app.sh` re-signs Sparkle's Installer and Downloader XPC services,
Autoupdate tool, Updater app, and framework inside-out before signing RelayBar.
Every nested boundary and the final bundle must pass strict code-signature
verification. Appcast generation accepts only the final archive rebuilt after
stapling; never sign a pre-notarization or pre-staple ZIP. Production
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
Release download links identify the current stable version explicitly.
