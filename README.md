# RelayBar

RelayBar is a tiny native macOS menu-bar app for local SSH port forwards. It has no external dependencies and runs macOS's built-in `/usr/bin/ssh` directly.

[Download the latest release](https://github.com/lx2026/RelayBar/releases/latest)

## Screenshots

<p align="center">
  <img src="docs/screenshots/relaybar-tunnels.png" alt="RelayBar tunnel list" width="360">
  <img src="docs/screenshots/relaybar-add-tunnel.png" alt="RelayBar new tunnel form" width="360">
</p>

## What it does

- Imports common commands such as `ssh -N -L 8080:localhost:3000 user@host`
- Adds tunnels manually with five small fields
- Starts and stops each tunnel with one click
- Starts a tunnel and opens its local URL in the default browser with one click
- Retries unexpected disconnects up to 10 times with exponential backoff
- Shows startup failures directly beside the tunnel
- Stores tunnel definitions in local `UserDefaults`
- Stops child SSH processes when RelayBar quits

RelayBar intentionally manages one local (`-L`) forward per item. Safe connection options such as `-p`, `-J`, `-i`, and a restricted set of `-o` values are preserved when importing a command. Options that can execute local commands, select arbitrary configuration files, or write logs are rejected. RelayBar never invokes a shell.

RelayBar is distributed outside the Mac App Store and is intentionally not sandboxed. Its SSH process behaves like the command-line client: it reads the user's normal `~/.ssh/config` and `known_hosts`, can use configured identity files, and inherits access to the user's SSH agent. SSH still runs non-interactively, so password prompts are not supported. On recent macOS versions, the first connection to a `.local` or LAN host may ask for Local Network access.

## Roadmap

RelayBar handles the few steps between a remote server and your Mac. Use Claude Code, Codex, or a terminal to search and edit on the remote machine.

1. **Port forwarding** (complete)
   - ~~Import a standard `ssh -N -L` command.~~
   - ~~Add, edit, and delete a forward by hand.~~
   - ~~Save forward definitions locally.~~
   - ~~Start and stop each forward from the menu bar.~~
   - ~~Start a stopped forward and open its URL in the default browser.~~
   - ~~Retry an unexpected disconnect up to 10 times.~~
   - ~~Show connection errors beside the affected forward.~~
   - ~~Stop managed SSH processes when RelayBar quits.~~
2. **Remote files** (planned)
   1. **Open a pasted path:** paste an absolute path copied from remote `pwd`, choose a saved server, and open that folder.
   2. **Navigate folders:** show the files and subfolders at that path, with basic navigation and refresh. No search or indexing.
   3. **Download a file:** choose a local destination, track progress, cancel, and reveal the result in Finder.
   4. **Download a folder:** transfer a folder recursively, show progress, and allow cancellation.
   5. **Preview images:** preview one supported remote image at a time.
   6. **Render Markdown:** render remote Markdown in a safe, read-only view.

Remote file operations stop at opening, previewing, and downloading.

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
xcrun notarytool store-credentials relaybar-notary \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID \
  --password YOUR_APP_SPECIFIC_PASSWORD

NOTARY_PROFILE=relaybar-notary ./scripts/notarize-release.sh
```

Set `SIGNING_IDENTITY` only when a Mac has multiple Developer ID certificates and the automatic choice is not the one you want.

## Test

```bash
swift test
```
