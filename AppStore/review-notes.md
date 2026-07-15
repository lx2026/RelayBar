# App Review notes

RelayBar is a menu-bar-only macOS utility (`LSUIElement`) for user-configured local SSH port forwards.

## How to review

1. Click the RelayBar arrows in the macOS menu bar.
2. Click **Add your first tunnel**.
3. Paste a reviewer-controlled command in the form `ssh -N -L 8080:localhost:3000 user@host`, or fill the five fields manually.
4. Click **Choose key…** and grant read-only access to a reviewer-controlled identity file.
5. Click **Add Tunnel**, then the play button.

The reviewer will need an SSH host reachable with non-interactive key authentication to observe a running connection. The App Store build requires an explicitly selected identity key because it intentionally has no broad access to `~/.ssh`. An unavailable host produces a visible inline error state.

## Security and process behavior

- RelayBar invokes the macOS system SSH executable directly and never invokes a shell.
- The sandboxed build keeps a private known-hosts file and uses security-scoped, read-only access for a user-selected identity key. It does not request access to the user's entire `.ssh` directory.
- It rejects remote commands, dynamic and remote forwards, custom SSH configuration files, and SSH options that can execute local commands.
- Child SSH processes stop when the user stops a tunnel or quits RelayBar.
- The app does not install helpers, daemons, login items, or code.

## Data and accounts

- No account is required.
- No analytics, advertising, telemetry, or third-party SDK is included.
- Tunnel definitions are stored only in the app's local preferences.
- SSH authentication is handled by the operating-system SSH client; RelayBar does not collect passwords or private keys.
