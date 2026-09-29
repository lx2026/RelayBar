# RelayBar

RelayBar is a tiny native macOS menu-bar app for structured SSH forwarding profiles and exact-path remote file access. It runs macOS's built-in `/usr/bin/ssh` and `/usr/bin/sftp` directly.

[Download v1.6.0](https://github.com/lx2026/RelayBar/releases/download/v1.6.0/RelayBar.zip)
· [Changelog](CHANGELOG.md)

## Install

Install the current stable release with Homebrew:

```bash
brew install --cask lx2026/tap/relaybar
```

Later releases can be installed with:

```bash
brew upgrade --cask lx2026/tap/relaybar
```

If RelayBar was previously installed manually, quit it and remove the existing
`/Applications/RelayBar.app` before the first Homebrew installation. Homebrew
will not overwrite an application that it does not manage.

## Screenshots

RelayBar 1.6.0 adds configurable SSH retries, a five-second Undo window before
remote deletion, JSON and MP4 previews, and clearer profile forms. The Remote
Files workspace keeps recent folders and host paths one click away.

<p align="center">
  <img src="docs/screenshots/relaybar-tunnels.png" alt="RelayBar tunnel list" width="360">
  <img src="docs/screenshots/relaybar-add-tunnel.png" alt="RelayBar new tunnel form" width="360">
</p>

<p align="center">
  <img src="docs/screenshots/remote-files-workspace.png" alt="RelayBar 1.5 Remote Files workspace with recent folders, recent hosts, Add Path, browsing, and upload" width="760">
</p>

<p align="center">
  <img src="docs/screenshots/remote-files-preview.png" alt="RelayBar 1.5 safely previewing a remote Markdown file beside recent locations" width="760">
</p>

## What it does

- Imports repeated and mixed `-L`, `-D`, and `-R` rules from forwarding-only SSH commands
- Supports TCP ports, Unix sockets, local SOCKS, reverse SOCKS, and automatic remote ports
- Runs every rule in a profile over one managed SSH connection
- Optionally groups saved profiles into lightweight menu-bar sections
- Starts and stops each profile with one click
- Opens an unambiguous local TCP forward in the default browser with one click
- Retries unexpected disconnects with exponential backoff and a saved 0–100 retry limit in Settings (default 10; 0 disables retries)
- Shows startup failures directly beside the tunnel
- Stores tunnel definitions in local `UserDefaults`
- Stops child SSH processes when RelayBar quits
- Checks for signed updates on demand or, when enabled, once a week
- Reopens successful remote folders from a bounded local recent-location sidebar, or opens an exact path through a recent connection, saved host, forwarding profile, or concrete `~/.ssh/config` alias
- Uploads one local file into the open remote folder through failure-safe hidden staging, with byte and percentage progress plus explicit replacement consent
- Downloads remote files or folders with progress, cancellation, and Finder reveal
- Previews supported remote images without adding editing or gallery features
- Renders remote Markdown in a safe, read-only view with GFM, callouts, inert tags, syntax highlighting, footnotes, and native math
- Renders bounded UTF-8 JSON in a native, selectable, read-only syntax view
- Previews bounded remote MP4 video through native, paused-by-default playback controls
- Enters a reusable Select mode for file-only browser actions and offers a five-second Undo window before permanent single or bulk deletion; direct preview deletion advances after server acknowledgement

For example, Quick Add accepts `ssh -N -D 9999 -p 1234 user@server`, and one profile can combine local, SOCKS, and remote rules. A SOCKS client that should resolve names from the SSH server side must send hostnames through SOCKS, for example:

```bash
curl --socks5-hostname 127.0.0.1:9999 https://example.com
```

RelayBar provides TCP forwarding; it is not a UDP or DNS server and does not change macOS proxy or resolver settings. Reverse SOCKS has the opposite egress direction: clients on the SSH-server side request TCP connections from the Mac's network position. Remote non-loopback listeners also depend on the server's `GatewayPorts` policy.

Safe connection options such as `-p`, `-J`, `-i`, and a restricted set of `-o` values are preserved when importing a command. Forwarding declarations are parsed into typed rules. Options that can execute local commands, select arbitrary configuration files, or write logs are rejected. RelayBar never invokes a shell.

RelayBar is distributed outside the Mac App Store and is intentionally not sandboxed. Its SSH process behaves like the command-line client: it reads the user's normal `~/.ssh/config` and `known_hosts`, can use configured identity files, and inherits access to the user's SSH agent. SSH still runs non-interactively, so password prompts are not supported. On recent macOS versions, the first connection to a `.local` or LAN host may ask for Local Network access.

## Roadmap

RelayBar handles the few steps between a remote server and your Mac. Use Claude Code, Codex, or a terminal to search and edit on the remote machine.

1. **Port forwarding** (complete)
   - ~~Import a standard `ssh -N -L` command.~~
   - ~~Add, edit, and delete a forward by hand.~~
   - ~~Save forward definitions locally.~~
   - ~~Start and stop each forward from the menu bar.~~
   - ~~Start a stopped forward and open its URL in the default browser.~~
   - ~~Retry unexpected disconnects with exponential backoff and a configurable limit, including 0 to disable retries.~~
   - ~~Show connection errors beside the affected forward.~~
   - ~~Stop managed SSH processes when RelayBar quits.~~
   - ~~Combine repeated local, SOCKS, remote, and Unix-socket rules in one profile.~~
   - ~~Show OpenSSH-assigned remote ports and type-correct endpoint actions.~~
   - ~~Group saved profiles without changing their SSH process state.~~
2. **Remote files** (complete)
   1. ~~**Open a pasted path:** paste an absolute path copied from remote `pwd`, choose a saved server, and open that folder.~~
   2. ~~**Navigate folders:** show the files and subfolders at that path, with basic navigation and refresh. No search or indexing.~~
   3. ~~**Download a file:** choose a local destination, track progress, cancel, and reveal the result in Finder.~~
   4. ~~**Download a folder:** transfer a folder recursively, show progress, and allow cancellation.~~
   5. ~~**Preview images:** preview one supported remote image at a time.~~
   6. ~~**Render Markdown:** render GFM and common Obsidian reading syntax in a bounded, read-only native view. Remote images and embeds are not fetched, raw HTML is inert, and Mermaid remains source-only.~~
   7. ~~**Revisit common folders:** keep a bounded local list of successful host-and-folder pairs in one persistent split workspace.~~
   8. ~~**Upload one file safely:** stage one chosen local regular file and publish it only with the server's advertised hard-link or POSIX-rename guarantee.~~
   9. ~~**Preview JSON and show upload percentage:** render bounded JSON natively and measure exact staging bytes without weakening safe publication.~~
   10. ~~**Delete files directly:** offer five seconds to Undo before removing a revalidated browser selection sequentially or the current previewed file; keep image preview moving after acknowledged deletion.~~
   11. ~~**Select and act on files:** enter an explicit file-only selection mode whose first bulk action is permanent sequential deletion.~~
   12. ~~**Fix JSON reading and preview MP4:** soft-wrap and vertically scroll JSON, and play bounded MP4 files through native controls without autoplay.~~

Remote file operations stop at opening, previewing, downloading, explicit
single-file upload, and direct permanent deletion of selected regular files.
RelayBar does not search, mount, synchronize, or edit remote content, and it
does not provide remote Trash or recovery after deletion is submitted. Undo
is available during the five-second wait before submission.

Markdown rendering uses exactly pinned open-source packages. Required license text is bundled from [`THIRD_PARTY_NOTICES.txt`](Sources/RelayBar/Resources/THIRD_PARTY_NOTICES.txt).

## System specs

The concise architecture and behavior archive starts at [`docs/system-specs`](docs/system-specs/README.md).

## Build

Requires macOS 13 or newer and the Xcode command-line tools.

```bash
./scripts/build-app.sh
open .build/RelayBar.app
```

The packaged app is written to `.build/RelayBar.app`. The build script automatically finds the first valid **Developer ID Application** certificate in the login keychain and signs with the hardened runtime.

To create a signed ZIP:

```bash
./scripts/package-release.sh
```

This writes `.build/RelayBar.zip`. A Developer ID signature identifies the publisher, but a downloaded app should also be notarized to pass Gatekeeper without warnings. After storing one `notarytool` keychain profile, notarize and staple with:

```bash
xcrun notarytool store-credentials YOUR_NOTARY_PROFILE \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID \
  --password YOUR_APP_SPECIFIC_PASSWORD

NOTARY_PROFILE=YOUR_NOTARY_PROFILE ./scripts/notarize-release.sh
```

Set `SIGNING_IDENTITY` only when a Mac has multiple Developer ID certificates and the automatic choice is not the one you want.

Maintainer releases use the existing `AC_NOTARY` Keychain profile:
`NOTARY_PROFILE=AC_NOTARY ./scripts/notarize-release.sh`. See the
[release guide](docs/system-specs/operations/build-and-release.md) for credential
verification, signing, Sparkle, GitHub, website, and Homebrew publication.

## Test

```bash
swift test
```
