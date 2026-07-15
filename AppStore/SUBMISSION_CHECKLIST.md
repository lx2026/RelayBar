# Mac App Store submission checklist

## Developer account values

- [ ] Confirm the product name `RelayBar` is available in App Store Connect.
- [ ] Register the bundle identifier `com.lx2026.RelayBar`, or replace it everywhere before registration.
- [ ] Set the Apple Developer Team on the RelayBar Xcode target.
- [ ] Create the macOS app record in App Store Connect.
- [ ] Confirm agreements, tax, banking, and compliance status.

## Product and compliance

- [ ] On an unlocked Mac, choose an identity key and complete an end-to-end tunnel test in the signed App Sandbox build. System SSH launch, network access, sandboxed known-hosts storage, and blocked ungranted key access are already verified.
- [ ] Answer App Store Connect's encryption questions. RelayBar accesses standard encryption supplied by macOS SSH; Apple currently says OS-only encryption needs no documentation, but the account holder remains responsible for the declaration.
- [ ] Confirm the App Privacy answers match `PRIVACY.md`: no data collected and no tracking.
- [ ] Publish the privacy-policy and support URLs from the repository.
- [ ] Complete age rating and content-rights questions.
- [ ] Decide pricing and territories.

## Assets and metadata

- [x] 1024 px app icon and complete macOS icon set.
- [x] English name, subtitle, description, keywords, and promotional text.
- [x] App Review notes.
- [ ] Capture current App Store screenshots from the signed build.
- [ ] Add localized metadata if desired.

## Build and upload

- [ ] Run `DEVELOPMENT_TEAM=YOURTEAM ./scripts/archive-app-store.sh`.
- [ ] Validate the archive in Xcode Organizer.
- [ ] Upload to App Store Connect and wait for processing.
- [ ] Test the processed build through TestFlight for Mac.
- [ ] Attach the build to version 1.0 and submit for review.
