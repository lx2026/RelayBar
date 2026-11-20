# Task 067 — Switchboard popover, Settings window and new icon

Date: 2026-11-16. Committed locally as `5909f1c`; not pushed. A notarized RelayBar 2.0.0 (25), built from the committed tree and so including the shared palette, is installed for the owner's hand test (see [Local installation, build 25](#local-installation-build-25)); the hand checks below are still open.

## What changed

Popover (still 380 × 440 points):

- A 44-point header with the app name, "N active" or "All stopped", and an issue count when a tunnel has failed. The app mark is gone.
- Flat 46-point rows: a status glyph that differs by shape, the name, one second line with the port mapping and the host or status, and a switch. Open in Browser and the row menu appear on hover or keyboard focus; right-click opens the same menu. The "Retry" and "Issue" badges and the third line are gone; their full wording is in tooltips, and VoiceOver reads it.
- A local SOCKS rule's compact mapping now ends at "SOCKS", because the host follows it on the same line.
- Named group headers show one action, Start All or Stop All. The group menu now also holds Start All and Stop All, so a group with some members running keeps both.
- A 40-point footer with Remote Files and Quit. "Uses macOS SSH" moved to Settings.
- Popover scroll views use the overlay indicator whatever "Show scroll bars" is set to, and the list fades at its lower edge.
- The profile editor has the same 44-point header bar; its form is unchanged.

Settings is a 480-point-wide window that is always as tall as its content: General, the retry caption, Previews with one "Size limit" heading, the Frame access row when present, About, and a bottom row with "Uses macOS SSH" and the links. The gear and Command-comma open it; Command-W and Escape close it. A typed retry limit is saved on Return, on leaving the field, and when the window closes or stops being key.

The app icon is the Route mark, drawn by `Apps/RelayBar/scripts/render-app-icon.swift` with a simplified drawing at 32 pixels and below. The menu-bar glyph is the same mark as a template image: dimmed when idle, solid when a tunnel is starting, retrying or running, and followed by an exclamation mark when a tunnel has failed.

## Captures

Taken through the test capture harness with fixture data, in light and dark. Eight are kept here; all are in the git-ignored `.build/task-067-design/`.

- [Popover, grouped, light](assets/067-switchboard/popover-grouped-light.png) and [dark](assets/067-switchboard/popover-grouped-dark.png)
- [Six rows and two group headers without scrolling](assets/067-switchboard/popover-six-rows-dark.png)
- [Profile editor header](assets/067-switchboard/popover-editor-new-light.png)
- [Settings window](assets/067-switchboard/settings-default-light.png) and [with the Frame access row](assets/067-switchboard/settings-frame-access-dark.png)
- [Menu-bar glyph states](assets/067-switchboard/menu-bar-glyph-light.png)
- [Icon at every size](assets/067-switchboard/icon-review.png)

The captures draw switches that are on, and prominent buttons, in grey, because the test process is not the active app. In the Settings captures the About row shows a generic folder where the app icon goes, for the same reason.

## Acceptance

| Criterion | Evidence |
| --- | --- |
| Captures in both appearances match the mocks | Reviewed against the mock: header, row rhythm, status column, hover row, footer, Settings rows and columns. |
| No content cut off with scroll bars set to Always | `PopoverPresentationTests` set the default to Always and assert the overlay style and a document no wider than its viewport for the list and the editor. Settings no longer scrolls. Not yet seen in the real app. |
| Six rows and two headers fit | The capture test asserts every row lies inside the viewport: 354 points of content in 355. |
| Settings never scrolls | Each Settings capture asserts its height equals its content and that it holds no scroll view, including the Launch at Login note and the Frame access row. |
| Glyph states and accessibility label | `StatusItemGlyphTests` cover state choice, labels, sizes and drawing. Not yet seen in the real menu bar. |
| Icon in every size and in the build | The script writes all ten files; `actool` compiles the catalog without warnings; the icon extracted from the unsigned Release build is the Route mark. |
| Checks | 9 script tests; 94 shared tests with 3 skipped; 448 RelayBar tests with 31 skipped; 190 Frame tests with 2 skipped; no failures. Unsigned Release build succeeds; `git diff --check` is clean. Log: `.build/task-067-gate.log`. |

## Review

An independent read of the diff raised five points. Four were fixed: a typed retry limit lost when the window closed; a long port mapping squeezing the status text out; VoiceOver not hearing the retry attempt; hover highlights that could survive the popover closing. The fifth, a switch that might stay on after a start that fails the same way twice, did not reproduce on this macOS; the switch now refreshes itself after every request and a test holds the behaviour.

## Still to check by hand

- Switches are accent-coloured when on, and sit level with the text.
- Hover reveals the two row buttons; Tab reaches them; VoiceOver reads them; right-click opens the row and group menus.
- The starting and retrying arcs turn, and stay still under Reduce Motion.
- With "Show scroll bars" set to Always in System Settings, the list and the editor show the thin indicator and nothing is cut off.
- Opening Settings closes the popover and brings the window forward; Command-comma works from the popover; Escape closes Settings while the retry field is being edited; the retry field is not focused when the window opens.
- An error raised while Settings is open is shown once, not once per window.
- The glyph's three states in the real menu bar, in both appearances.
- The icon in the Dock, Finder and Spotlight, especially at 16 and 32 pixels.

## Left for the owner

- The website still carries the old icon: `docs/relaybar-icon.png`, `docs/favicon.png`, `docs/relaybar-social.png`, and the screenshots that show the old popover. They were not changed, because changing them changes the published site.
- The empty state was left as it was. Its title and button are now the largest things in the popover.
- The profile editor's form, the Plugins window and Remote Files were not redesigned.
- On this macOS the small switch draws 44 × 20 points in Settings and the mini switch 36 × 16 in the popover, larger than the mock's 32 × 18 and 30 × 18.

## Local installation, build 23

The owner approved building, notarizing and installing RelayBar 2.0.0, build 23, for a hand test. The source was the uncommitted working tree on top of commit `a896188`; the only change made for this build raised the build number from 22 to 23 in `Apps/RelayBar/Packaging/Info.plist` and both Xcode configurations. After fetching, the branch had no upstream and was two commits ahead of `origin/main`, zero behind. The tracked application patch and the five untracked source files were unchanged from build to installation.

- Apple submission `fd3856df-788f-449f-b1c7-d63f61f468a8`: Accepted, status code 0, no issues; team `39HYFR5Z65`, profile `AC_NOTARY`.
- Final ZIP SHA-256, after stapling: `fb267de544351f628f5746f58635c006b47b4fd49f957d45470e0422325d7363`.

Before building, the 9 release-script tests and the property-list, entitlements and project lint passed. The app suites were not rerun: the checks above passed on this tree and only the build number changed.

The clean extraction of the final ZIP and the installed bundle each passed: strict deep signature; Developer ID, hardened runtime and timestamp; App Group entitlement; stapled ticket; Gatekeeper as Notarized Developer ID; arm64 and x86_64; version 2.0.0 and build 23; matching dSYM UUIDs for both slices; renderer resources and notices. The bundle's icon images match the new Route icon in the working tree and differ from the icon at `a896188`; by eye it is the light body with the blue route. The ZIP is 5.5 MB against 7.3 MB for build 22 because the asset catalog shrank from 2.1 MB to 0.3 MB; the file list is identical.

The installed 2.0.0 (22) was archived first to `.build/local-notarized-install-2.0.0-build23-2026-11-16/backups/RelayBar-2.0.0-build22.zip`; that archive extracts and passes signature, ticket and Gatekeeper checks. RelayBar then quit normally, which stopped its tunnels, and `/Applications/RelayBar.app` was replaced with `ditto`. The installed executable matches the extraction. The new app completed launch as PID 19225, and Launch Services resolves `com.lx2026.RelayBar` to `/Applications/RelayBar.app`. Preferences and user data were not touched; Frame was not changed.

Logs, Apple's records, the final ZIP, checksums, the dSYM and the backup are in `.build/local-notarized-install-2.0.0-build23-2026-11-16/`. No commit, push, tag, release, feed, website or Homebrew change was made.

## After the hand check

The owner found that the installed build 23 popover could be scrolled sideways. The list and the editor sized their document from the popover's full 380-point width and relied on the overlay override to keep the viewport that wide, so whenever the scroll view was on the legacy scroller the document was 17 points wider than its viewport and a tilted wheel or a sideways swipe moved it; the override was in the installed build, and what put the scroll view back on the legacy scroller there was not reproduced in tests. The document is now always exactly as wide as the viewport, the backing scroll view has no horizontal scroller or elasticity, and its clip view is held at the leading edge; `PopoverScrollingTests` check this with the legacy scroller forced, with long names, hosts, messages and field values, and fail against the earlier code.

## Local installation, build 24

The owner approved building, notarizing and installing RelayBar 2.0.0, build 24, with Frame 2.0.0, build 18, for a hand test. The source was the uncommitted working tree on top of commit `a896188`, including the sideways-scroll fix above and Task 068; the only change made for this build raised the build number from 23 to 24 in `Apps/RelayBar/Packaging/Info.plist` and both Xcode configurations. After fetching, the branch had no upstream and was two commits ahead of `origin/main`, zero behind. The tracked application patch and the 17 untracked source files were unchanged from build to installation.

- Apple submission `02e49c78-5344-4726-9a8e-ad5fe6190f1f`: Accepted, status code 0, no issues; team `39HYFR5Z65`, profile `AC_NOTARY`.
- Final ZIP SHA-256, after stapling: `0423dfd5f8d879a30d537e8926182a61016d464f0fe317a422c464c0d177a3fd`.

Before building, the 9 release-script tests and the property-list, entitlements and project lint passed for both apps. The app suites were not rerun: they passed on this tree the same day and only build numbers changed.

The clean extraction of the final ZIP and the installed bundle each passed: strict deep signature; Developer ID, hardened runtime and timestamp; entitlements equal to the source file; stapled ticket; Gatekeeper as Notarized Developer ID; arm64 and x86_64; version 2.0.0 and build 24; matching dSYM UUIDs for both slices; renderer resources and notices. The icon images match the Route icon in the working tree and differ from the icon at `a896188`; by eye it is the light body with the blue route.

The installed 2.0.0 (23) was archived first to `.build/local-notarized-install-2.0.0-rb24-frame18-2026-11-16/backups/RelayBar-2.0.0-build23.zip`; that archive extracts and passes signature, ticket and Gatekeeper checks. RelayBar then quit normally, which stopped its tunnels, and `/Applications/RelayBar.app` was replaced with `ditto`. The installed executable matches the extraction. The new app completed launch as PID 34850 and was still running ten seconds later; Launch Services resolves `com.lx2026.RelayBar` to `/Applications/RelayBar.app`, and no new crash report appeared.

RelayBar was installed on its own. Frame build 18 was notarized and verified but not installed, because its catalog could not be backed up first; see [Task 068](068-frame-reader-layout.md#local-installation-build-18). Frame 2.0.0 (17) remains installed, as it was beside build 23. Logs, Apple's records, the final ZIPs, checksums, dSYMs and backups are in `.build/local-notarized-install-2.0.0-rb24-frame18-2026-11-16/`. No commit, push, tag, release, feed, website or Homebrew change was made.

## Local installation, build 25

The owner approved building, notarizing and installing RelayBar 2.0.0, build 25, with Frame 2.0.0, build 19, so that both installed apps carry the shared palette of [Task 069](069-shared-paper-palette.md). The source was commit `3d140fa` with a clean tree; the only change made for this build raised the build number from 24 to 25 in `Apps/RelayBar/Packaging/Info.plist` and both Xcode configurations. The branch had no upstream and was six commits ahead of `origin/main`, zero behind. The tracked application patch was unchanged from build to installation.

- Apple submission `6090a7f3-6531-47bb-8815-7ff675850d39`: Accepted, status code 0, no issues; team `39HYFR5Z65`, profile `AC_NOTARY`.
- Final ZIP SHA-256, after stapling: `48bfac53e09cc5d213bf82edc9d841bef758a05fe5da89d418c0a18078080245`.

Before building, the 9 release-script tests and the property-list, entitlements and project lint passed for both apps. The app suites were not rerun: they passed on this tree the same day and only build numbers changed.

The clean extraction of the final ZIP and the installed bundle each passed the checks listed for build 24, at build 25. Both slices of the Release executable load `libswiftObservation` through `LC_LOAD_WEAK_DYLIB` and have a minimum OS of 13.0, which is what lets the palette's macOS 14 code sit in a macOS 13 app; the app has not been launched on macOS 13.

The installed 2.0.0 (24) was archived first to `.build/local-notarized-install-2.0.0-rb25-frame19-2026-11-17/backups/RelayBar-2.0.0-build24.zip`; that archive extracts with a valid signature and the same executable as the installed app. RelayBar then quit normally, which stopped its tunnels, and `/Applications/RelayBar.app` was replaced with `ditto`. The installed executable matches the extraction. The new app completed launch and was still running ten seconds later; Launch Services resolves `com.lx2026.RelayBar` to `/Applications/RelayBar.app`, and no new crash report appeared.

Frame 2.0.0 (19) was installed in the same round; see [Task 068](068-frame-reader-layout.md#local-installation-build-19). Logs, Apple's records, the final ZIPs, checksums, dSYMs and backups are in `.build/local-notarized-install-2.0.0-rb25-frame19-2026-11-17/`. No push, tag, release, feed, website or Homebrew change was made.

## Local installation, build 31

On 2026-11-20, RelayBar 2.0.0 (31) was built from `7de575a`. When macOS launched build 30 hidden, clicking the status item could give the popover keyboard focus while its window stayed off screen. Build 31 calls `NSApp.unhideWithoutActivation()` when the menu content appears.

An isolated app using the production menu content exercised three open-and-dismiss cycles after a forced hidden launch and three after an ordinary background launch. WindowServer showed the 380 × 440 popover on every open, including the first from the hidden state, and removed it on every dismissal. The macOS suite reported 436 passes, 35 skips and zero failures. All 17 script tests passed.

Apple accepted submission `2f25e1a1-9ad8-419b-a829-ac762cba270c`. The stapled ZIP's SHA-256 was `04ea87b3deeee3d5d0f00f10cb9d3b9b36e26d2cfd73bd86d4906a7264914767`. Both executable slices matched the release dSYM. The installed copy passed strict signature verification, ticket validation and Gatekeeper assessment as Notarized Developer ID.

Build 30 quit with no active SSH transfers or tunnels and was saved at `.build/app-backups/build30-before-31-20261120-133744/RelayBar.app`. Build 31 completed launch from `/Applications/RelayBar.app` and registered its menu bar icon. Desktop automation could inspect the installed icon but could not confirm a visible popover from a pointer click. The six verified cycles above used the isolated app.
