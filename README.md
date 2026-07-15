# RelayBar

RelayBar is a tiny native macOS menu-bar app for local SSH port forwards. It has no external dependencies and runs macOS's built-in `/usr/bin/ssh` directly.

## What it does

- Imports common commands such as `ssh -N -L 8080:localhost:3000 user@host`
- Adds tunnels manually with five small fields
- Starts and stops each tunnel with one click
- Shows startup failures directly beside the tunnel
- Stores tunnel definitions in local `UserDefaults`
- Stops child SSH processes when RelayBar quits

RelayBar intentionally manages one local (`-L`) forward per item. Safe connection options such as `-p`, `-J`, and a restricted set of `-o` values are preserved when importing a command. An imported `-i` path is recognized, then macOS asks the user to choose that key so the App Store sandbox can grant read-only access. Options that can execute local commands, select arbitrary configuration files, or write logs are rejected. RelayBar never invokes a shell.

SSH runs non-interactively, so hosts should use key authentication. The App Store build asks the user to choose an identity key, keeps its own known-hosts file, and does not read arbitrary `~/.ssh/config`; use `user@host` plus the preserved port or jump-host options. On recent macOS versions, the first connection to a `.local` or LAN host may ask for Local Network access.

## Build

Requires macOS 13 or newer and the Xcode command-line tools.

```bash
./scripts/build-app.sh
open .build/RelayBar.app
```

The packaged app is written to `.build/RelayBar.app`. The build script applies an ad-hoc local signature.

For Mac App Store archiving, open `RelayBar.xcodeproj` in Xcode and select your Developer Team, or run:

```bash
DEVELOPMENT_TEAM=YOURTEAM ./scripts/archive-app-store.sh
```

## Test

```bash
swift test
```
