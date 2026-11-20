# Security Policy

## Supported versions

Security fixes are provided for the latest released version of RelayBar.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository. Do not include private keys, passwords, production hostnames, or other secrets in a report. If private reporting is unavailable, open an issue that contains no sensitive details and request a private contact channel.

## Mac apps

RelayBar's security boundary is intentionally narrow: it invokes `/usr/bin/ssh` for typed local, SOCKS, remote, and Unix-socket forwarding rules and `/usr/bin/sftp` for Remote Files using fixed executable paths, structured arguments, and no shell. Imported options capable of executing local commands or selecting arbitrary configuration files are rejected. Reverse SOCKS requires a visible destination policy, non-loopback listeners are called out, and RelayBar never replaces an unowned filesystem entry at a local socket path. Remote paths, listings, downloads, images, and Markdown are treated as untrusted input and bounded where RelayBar parses or renders them. Markdown HTML and Mermaid never execute, document images and embeds never load, and only user-clicked absolute web or email links reach macOS. See [the security review](docs/SECURITY_REVIEW.md) for the current threat model and residual risks.

## iPhone and iPad

The built-in SSH client checks the host key before offering credentials. On first connection, compare the displayed fingerprint with one obtained from the host operator. A changed pin stops sign-in. The client tries tailnet identity, then a device key, then a password. The Secure Enclave creates the P-256 private key on first need and signs on the device. Only the public key can be copied. Remembering a password is optional. A saved password is a this-device-only Keychain item.

Profiles and reading history stay on the device. Cached files are purgeable and kept apart by profile, account, host-key fingerprint and path. Settings can clear one host’s cached copies. Deleting the app and its local data clears profiles and history. File contents travel between the device and the configured SSH host. RelayBar has no account service, analytics or third-party collection. Markdown runs with page scripts disabled.

### Web services and HTML previews

For an HTTP service, the browser first tries the host directly over the user’s VPN; an HTTPS service opens under the private name. For a host service bound to loopback, the browser uses a private name through the app’s authenticated loopback proxy. The transport library restricts proxy connections to allowed names and ports. The browser fails closed if the proxy refuses access.

A service that needs the exact name `localhost` requires the user to enable a device listener for that service. The gate checks every HTTP request’s host, any supplied origin, cross-site request metadata and a service token. It strips the token before forwarding. A page on the service can read the token from its user agent and reuse it. Servers the page contacts can also receive it there. The token does not prove the sender’s identity. Closing the page revokes its token. Leaving the foreground closes the listeners and their connections.

With HTML Scripts enabled, HTML file previews run scripts in a temporary store without service tokens or proxy access. Internet resources require separate permission for each host.
