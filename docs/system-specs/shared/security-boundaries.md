# Security Boundaries

- RelayBar invokes `/usr/bin/ssh` directly and never invokes a shell.
- Forwarding input becomes typed Local, Local SOCKS, Remote, or Remote SOCKS rules. Persisted profiles and structured settings are validated again immediately before launch.
- Optional group tags are bounded, single-line local display metadata. They are never passed to SSH, SFTP, a shell, or Remote Files connection identity.
- The managed master clears SSH-config forwarding declarations, and its `-F none` control helpers add only the rules visible in RelayBar. Normal connection, identity, host-key, agent, and jump-host configuration remains available to the master.
- Remote Files invokes `/usr/bin/sftp` directly with structured arguments and batch input; it also never invokes a shell.
- Host values cannot be empty, option-shaped, whitespace-separated, or contain control characters.
- Additional arguments must match the explicit allowlist in `SSHArgumentPolicy`; values must be nonempty and contain no control or newline characters.
- Options that execute commands, choose arbitrary config files, or write logs are blocked.
- Remote Files reads at most 1 MiB from `~/.ssh/config` and exposes at most 256 concrete `Host` aliases. Wildcard, character-pattern, and negated aliases are ignored; RelayBar does not modify the config.
- SSH uses batch mode; password prompts are unsupported.
- Private control sockets live in random app-owned `0700` temporary directories. Control output is bounded and operations time out.
- Normal SSH configuration, known hosts, identity files, and the user's SSH agent remain available.
- Remote paths must be absolute, single-line, and no more than 32 KiB of UTF-8. SFTP batch values escape quotes and backslashes. Listing basenames containing path separators or control characters are ignored; absolute listing names are accepted only when they resolve to direct children of the requested folder.
- Remote listings are capped at 10,000 supported entries, 32 KiB per line, and 4 KiB per entry name; negative sizes are rejected. Captured SFTP output is capped at 32 MiB, captured SFTP diagnostics at 1 MiB, image previews at 100 MiB, and Markdown previews at 2 MiB.
- Command output and previews use private temporary directories. Downloads use a hidden `0700` staging directory beside the chosen destination and replace existing content only after success.
- Cancellation, failure, preview exit, window close, and app quit clean up owned temporary content.
- Markdown accepts UTF-8 without NULs. HTML-looking spans, including multi-line tags and tags in link labels, are escaped before parsing so raw tags stay literal and never execute; images and embeds never load; Mermaid never executes.
- Only clicked absolute HTTP, HTTPS, and email links without credentials or raw/percent-decoded control characters reach macOS. Relative Markdown references apply the same decoded-control rejection. Private wiki, tag, footnote, and math references require a random per-preview capability token; remote-authored forgeries remain blocked.
- Syntax highlighting is limited to 64 KiB from an explicit supported language and 128 labelled blocks per document, using a bundled highlighter without DOM or network access.
- Math is syntax-validated and limited to 4,096 characters per formula, 256 formulas per document, and bounded output dimensions. Named and inline footnotes, internal links, and embed placeholders are also count-bounded; invalid and overflow content remains readable source.
- Rendering dependencies use exact package versions and their notices are bundled with the app.
- RelayBar never reads, copies, logs, or stores private-key contents.
- Newly imported and manually created TCP listeners default to explicit loopback. Each explicit non-loopback listener is called out with its local or remote location.
- Local SOCKS lets reachable clients request outbound TCP connections from the SSH server. RelayBar does not provide SOCKS UDP association or control whether clients delegate hostname resolution.
- Remote SOCKS lets reachable server-side clients request outbound TCP connections from the Mac. Every such profile requires and displays an effective validated `PermitRemoteOpen` policy.
- Remote non-loopback listeners may expose Mac-side destinations and require compatible server `GatewayPorts` policy.
- Unix paths are absolute and single-line. RelayBar forces OpenSSH's broad `StreamLocalBindUnlink` behavior off, refuses every pre-existing local filesystem entry, and removes a created local socket only while its recorded device, inode, and socket type still match. An imported or selected unlink request permits only another app-owned cleanup attempt during the current run. Remote socket cleanup is controlled by OpenSSH and the server.
- Browser launch fixes the scheme to HTTP, falls back to `localhost` for wildcard local binds, and is unavailable for SOCKS, Unix, or remote listeners.

Detailed threat review: [Security review](../../SECURITY_REVIEW.md).
