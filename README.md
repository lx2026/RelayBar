# RelayBar and Frame

RelayBar keeps SSH forwarding profiles in your Mac's menu bar and opens remote files by path. Frame is its companion for reviewing images, video and documents in a folder workspace. Both are native macOS apps; RelayBar runs the system's `/usr/bin/ssh` and `/usr/bin/sftp` directly.

[Download stable RelayBar v1.6.0](https://github.com/lx2026/RelayBar/releases/download/v1.6.0/RelayBar.zip) · [RelayBar 2.0.0 Beta 1](https://github.com/lx2026/RelayBar/releases/tag/v2.0.0-beta.1) · [Frame 2.0.0 Beta 1](https://github.com/lx2026/RelayBar/releases/tag/frame-v2.0.0-beta.1) · [Changelog](CHANGELOG.md) · [Frame source](Apps/Frame)

## Availability

| | Stable 1.6.0 | 2.0.0 beta |
| --- | --- | --- |
| RelayBar | **1.6.0, build 11**, notarized; macOS 13+. In-app updates and Homebrew. | [**2.0.0 Beta 1, build 26**](https://github.com/lx2026/RelayBar/releases/tag/v2.0.0-beta.1), notarized; macOS 13+. Manual download. |
| Frame | Not part of the stable release. | [**2.0.0 Beta 1, build 20**](https://github.com/lx2026/RelayBar/releases/tag/frame-v2.0.0-beta.1), notarized; macOS 14+. Frame's first public build. Manual download and updates. |

The two betas are a pair. They use **bridge v7** and reject older versions with an update message, so remote folders in Frame need both betas, or both apps built from the same revision. Local folders in Frame work without RelayBar. Stable 1.6.0 does not include the Frame integration, plugins, the redesigned interface or the shared Markdown renderer.

## Install stable RelayBar

```sh
brew install --cask lx2026/tap/relaybar
```

Homebrew installs 1.6.0. The cask and RelayBar's update feed stay on 1.6.0 during the beta. Update with `brew upgrade --cask lx2026/tap/relaybar`, or use RelayBar's **Check for Updates…**. Automatic checks are optional; downloads and installation require user action.

If RelayBar was installed manually, quit it and remove the existing `/Applications/RelayBar.app` before the first Homebrew installation. Homebrew does not overwrite an app it does not manage. Keep application data to retain your profiles and recent locations.

## Try the 2.0.0 beta

Download `RelayBar.zip` from [RelayBar 2.0.0 Beta 1](https://github.com/lx2026/RelayBar/releases/tag/v2.0.0-beta.1) and `Frame.zip` from [Frame 2.0.0 Beta 1](https://github.com/lx2026/RelayBar/releases/tag/frame-v2.0.0-beta.1). Both are universal, Developer ID signed, notarized and stapled. Quit RelayBar first (quitting stops its tunnels), then move each app to Applications. RelayBar 2.0.0 keeps 1.6.0's saved profiles, hosts and recent locations, and imports its retry limit and update-check choice once.

Neither beta is offered by RelayBar's update feed or Homebrew, and Frame has no updater, so a newer beta build is downloaded by hand from its release.

## RelayBar

- Import repeated or mixed `-L`, `-D` and `-R` rules from forwarding-only SSH commands.
- Combine TCP, Unix sockets, local/reverse SOCKS and automatic remote ports over one connection per profile.
- Group profiles; start, stop, retry and open supported local endpoints from the menu bar.
- Set an SSH retry limit from 0–100. Unexpected disconnects retry with exponential backoff; 0 disables retries.
- Reopen recent remote folders or paste an exact path using a saved host, forwarding profile or concrete SSH-config alias.
- Upload one file through failure-safe staging; download files and folders with progress and cancellation.
- Preview images, Markdown, JSON and MP4. Permanent remote deletion has a five-second Undo window before submission.

For example, Quick Add accepts `ssh -N -D 9999 -p 1234 user@server`. To resolve a SOCKS destination on the SSH-server side:

```sh
curl --socks5-hostname 127.0.0.1:9999 https://example.com
```

RelayBar forwards TCP; it does not provide UDP or DNS service or change macOS proxy settings. Reverse SOCKS makes connections from the Mac's network position. Remote non-loopback listeners also depend on the SSH server's `GatewayPorts` policy.

<p align="center">
  <img src="docs/screenshots/relaybar-tunnels.png" alt="Stable RelayBar tunnel list" width="360">
  <img src="docs/screenshots/remote-files-preview.png" alt="Stable RelayBar 1.6.0 remote Markdown preview" width="760">
</p>

## 2.0.0 beta: interface, Frame, plugins and documents

These features are in the 2.0.0 betas and the current source, not in stable 1.6.0. Hand acceptance in the running apps and against live SSH hosts is not finished.

**RelayBar's popover** has a header with the number of active tunnels and any issues, then one flat line per profile: a status mark that differs by shape as well as colour, the name, the port mapping with the host or status, and a switch. Open in Browser and the row menu appear under the pointer or keyboard focus; right-click opens the same menu. Group headers show Start All or Stop All, and the footer holds **Remote Files…** and **Quit**. The app and menu-bar icon is a new route mark; in the menu bar it dims when nothing is running and adds an exclamation mark when a tunnel has failed.

**RelayBar Settings** is now its own window, opened with the gear or Command-comma: Launch at Login, Automatic Updates, SSH Retry Limit and Plugins; a switch and size limit for each preview format; Frame access, with Revoke, once granted; and About with **Check for Updates…**. Remote Files also previews HTML pages and, with Open in Frame on, opens the current folder in Frame.

**Frame** opens existing folders without importing files. Its window has two columns. The library column holds a Files/Icons switch, search, the folder tree and a footer with the kind filter, favourites and Archive. The reader column shows one file in Files mode, with Previous/Next and its actions in one top row, or the folder as thumbnails in Icons mode. Images and video sit beside a details rail with generation prompts, capture or video values and sidecar files. General files remain visible even without a preview. Favorites, companion-file grouping, Archive/Restore and exact-copy export keep related files together. Local deletion uses macOS Trash with Undo; remote Delete is immediate and permanent, with no confirmation or Undo. Frame never changes RelayBar's recent-folder history.

Frame's **review aids**: Markdown and HTML have a Rendered/Source switch. Beside rendered Markdown, **On this page** lists the second- and third-level headings, marks the section being read and scrolls to a chosen heading. A dot marks files changed since they were last opened in Frame; only file times are compared, so nothing is marked when a folder is first listed.

**Plugins** can be switched in either app's Plugins window (RelayBar: **Settings › Plugins**; Frame: **Frame › Plugins…**). It shows each plugin's status and reason, a map of the running features and what they depend on, and what else would unload with a plugin. These are built-in features, not downloadable third-party code.

| App | Plugin | Default | What it does |
| --- | --- | --- | --- |
| RelayBar | Reconnect on Wake | On | Brings a waiting retry forward after wake or network return, preserving its retry budget. |
| RelayBar | Service Labels | Off | Checks forwarded loopback HTTP endpoints for a short product or page label, every 30 seconds while enabled. |
| RelayBar | Open in Frame | On if Frame is installed at launch | Shows Open in Frame in Remote Files and runs the local bridge Frame uses; while off, RelayBar shows nothing of Frame. |
| Both | Paper Appearance | On | Draws the shared warm paper colours, light and dark; off uses standard macOS colours. |
| Frame | Prompt Search | On | Filters the current folder by filenames and companion text; Command-F focuses search. |

**Paper Appearance** covers RelayBar's popover, Settings, Remote Files and Plugins window, and all of Frame. Each app keeps its own choice, and switching it redraws open windows at once. With it off, a few RelayBar surfaces do not exactly match 1.6.0: the Settings window and the Plugins window's side columns sit on a grey background, the running and retrying marks use macOS green and orange, and status text uses macOS orange and red adjusted for contrast.

**Markdown** uses one shared renderer in both apps: highlighted code with Copy, typeset math, callouts, footnotes, frontmatter properties and aligned tables. Each app keeps its own palette and resource policy. Raw Markdown HTML is literal text; Mermaid remains source. Frame skips enrichment above 2 MiB; RelayBar limits Markdown input to 2 MiB.

Measured on the same dense test documents, RelayBar's warm preview time fell from 0.9 s to about 0.04 s at 20 KB and from 7.2 s to about 0.5 s at 200 KB. Frame's 200 KB preview grew from 0.07 s to 0.32–0.51 s with enrichment; 1 MB took about 1.6 s. These are local fixture measurements, not startup or remote-transfer guarantees. [Renders, method and limitations](docs/verification/063-one-markdown-renderer.md).

## Access and document boundaries

RelayBar is intentionally not sandboxed. It uses your normal SSH config, known hosts, identity files and agent; non-interactive connections cannot ask for passwords. Imported command options that execute local commands, select arbitrary config files or write logs are rejected. RelayBar invokes no shell. macOS may ask for Local Network access for LAN hosts.

Frame is sandboxed and uses selected-folder access for local files. Remote operations go through the authenticated local bridge to RelayBar, which retains SSH credentials and authority. The first Open in Frame asks before Frame may view, archive and permanently delete remote files; Revoke in RelayBar's Settings ends that access. Both apps verify the other's signed identity.

RelayBar's Markdown preview runs no document script and fetches no document images or embeds; clicked web/email links go to macOS. Frame's Markdown can load images and follow neighbouring document links. **HTML previews in both apps can run page scripts and load online resources.** HTML has no bridge to file actions, shell commands or clipboard writes. See [document security boundaries](docs/system-specs/shared/security-boundaries.md).

## Build and test

Use full Xcode with Swift 6.2 or newer and the macOS SDK. RelayBar targets macOS 13+; Frame targets macOS 14+. Signed app bundles require a Developer ID Application certificate.

From the repository root:

```sh
./scripts/test.sh                         # shared package and both apps
./scripts/build-app.sh release            # .build/RelayBar.app
./Apps/Frame/Scripts/build-app.sh release  # Apps/Frame/.build/app/Frame.app
```

Frame builds target Apple silicon (`arm64`) on macOS 14 or later. Intel users can download [Frame 2.0.0 Beta 3, build 23](https://github.com/lx2026/RelayBar/releases/tag/frame-v2.0.0-beta.3). RelayBar Release builds support Apple silicon and Intel.

For development without a signing identity, run `swift build --package-path Apps/Frame --product Frame` or build RelayBar's Xcode target with `CODE_SIGNING_ALLOWED=NO`. These do not replace the signed app-bundle workflow.

Local packaging accepts an app name:

```sh
./scripts/package-release.sh relaybar
./scripts/package-release.sh frame
```

After explicit distribution approval, `scripts/notarize-release.sh relaybar` or `scripts/notarize-release.sh frame` uses the selected app's archive. Set `NOTARY_PROFILE` to your Keychain profile and `RELAYBAR_PUBLICATION_APPROVED=yes` for that invocation. The script requires an Accepted result, staples, rebuilds the ZIP and verifies a clean extraction. The maintainer's existing profile is `AC_NOTARY`; no credentials belong in the repository. See the [release guide](docs/system-specs/operations/build-and-release.md).

## Source layout

- `Apps/RelayBar`: menu-bar app, SSH/SFTP operations, bridge host and Xcode project.
- `Apps/Frame`: sandboxed folder, media and document viewer.
- `Packages/AppComposition`: composition kernel, plugin UI, bridge protocol, preview contracts, grouping, Markdown rendering and the shared palette.
- `scripts/`: tests, builds and distribution tools. `docs/`: static website, specifications and verification.

The apps retain separate bundle identities and release artifacts. RelayBar's Sparkle feed and Homebrew cask remain its own. Start with the [system specs](docs/system-specs/README.md) and [adding a feature](docs/system-specs/shared/adding-a-feature.md). Dependency versions are pinned; required notices and font licenses ship in the app bundles.
