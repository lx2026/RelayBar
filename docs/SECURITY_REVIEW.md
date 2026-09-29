# RelayBar security review

Review date: September 29, 2026 (1.6.0 additions; prior findings retained)

## Scope and threat model

This review covers command import, tunnel persistence, child-process management, Remote Files paths/listings/transfers/deletion/image, Markdown, JSON and MP4 previews, diagnostic output, network exposure, rendering dependencies, Developer ID packaging, and accidental secret publication. It assumes an attacker may provide a crafted command or remote path, tamper with RelayBar's preferences, or control names, metadata, bytes, Markdown, code snippets, formulas, URLs, and diagnostics returned by a remote SSH server. The user's existing SSH configuration is trusted to the same extent it is when running the macOS OpenSSH clients in Terminal.

## Findings remediated

### SR-01 — Unsafe OpenSSH options could execute local commands (high)

The initial importer preserved arbitrary `-o` values and custom `-F` configuration files. OpenSSH options such as `ProxyCommand`, `LocalCommand`, and `KnownHostsCommand` can execute local programs even though RelayBar never invokes a shell itself.

Remediation: the importer and runtime now share an allowlist. Forwarding-only `-L`, `-D`, and `-R` values are parsed into typed rules rather than preserved as arbitrary arguments. Command-executing options, custom config files, log files, user-selected control sockets, and remote commands remain rejected. Accepted option values must be nonempty and cannot contain control or newline characters, preventing a persisted or quoted value from smuggling another configuration line. `PermitRemoteOpen`, `StreamLocalBindMask`, and `StreamLocalBindUnlink` have dedicated validators. Runtime validation also protects against a tampered preferences payload.

### SR-02 — A manual SSH host could be interpreted as an option (high)

A manually entered target beginning with `-` could be parsed by OpenSSH as another option.

Remediation: SSH targets must be a single non-control, non-whitespace token and cannot begin with `-`. The same validation runs again immediately before process launch.

### SR-03 — Non-loopback bind addresses were easy to overlook (medium)

An imported `-L 0.0.0.0:...` or wildcard bind can expose a forwarded service to other machines.

Remediation: newly imported and manually created listeners default to explicit loopback. Every explicit non-loopback listener displays a rule-specific warning naming whether exposure occurs on the Mac or SSH server.

### SR-10 — Flexible forwarding expands network and filesystem authority (high)

Local SOCKS can let other local-network clients request connections from the SSH server; Remote and Remote SOCKS can expose Mac-side services or network reachability to server-side clients. Unix listeners can also overwrite pathnames if OpenSSH's general unlink behavior is enabled without ownership checks.

Remediation: Local and Remote SOCKS are distinct typed rules and are never offered as HTTP URLs. Remote SOCKS requires a visible `PermitRemoteOpen` policy. Remote wildcard binds are explicit and warn that the server controls `GatewayPorts`. Imported omitted binds become `localhost`. The SSH master clears config-defined forwards, then bounded `-F none` control helpers install only visible rules. Private control paths live in random `0700` directories. Local Unix listeners preflight the exact path, refuse every existing entry, and force OpenSSH unlinking off. A requested `StreamLocalBindUnlink=yes` is narrowed to retrying cleanup of a socket whose type, device, and inode RelayBar recorded during the current app run. Remote Unix cleanup remains server-controlled.

### SR-04 — Unbounded child-process diagnostics (low)

Long-running verbose SSH output could otherwise consume memory.

Remediation: stderr is continuously drained and capped to the most recent 16 KiB. Only the last two lines are displayed.

### SR-05 — SFTP batch-command injection through paths or names (high)

Remote paths and listing names are untrusted. Passing a line break or unescaped quote to SFTP batch input could create another client command.

Remediation: launcher paths must be absolute, contain no control characters, and fit a 32 KiB UTF-8 bound. Batch values apply the same bound, quote values, and escape backslashes and double quotes. Parsed names containing separators or control characters are discarded. `/usr/bin/sftp` is invoked directly and no shell evaluates either paths or connection values.

### SR-06 — Untrusted listings, diagnostics, and images could exhaust resources (medium)

A hostile server could return an extremely large listing, diagnostic stream, or image.

Remediation: parsed listings are capped at 10,000 supported entries, 32 KiB per line, and 4 KiB per entry name; negative sizes are rejected. Captured SFTP standard output is capped at 32 MiB, captured standard error at 1 MiB, and image preview candidates at 100 MiB. ImageIO validates dimensions and pixel count before creating a bounded thumbnail from private temporary storage.

### SR-07 — Partial or canceled transfers could replace local data (medium)

A failed recursive transfer must not leave an existing destination half-replaced.

Remediation: downloads use a hidden staging directory created with mode `0700` in the selected destination directory before SFTP writes its payload. Existing files or folders remain in place until SFTP succeeds, then replacement occurs as one filesystem operation. Cancellation or failure terminates SFTP and removes the complete staging directory. Preview and command-output directories use private permissions and are removed after use.

### SR-08 — Markdown active content could execute code or disclose data (high)

A remote document may contain raw HTML, JavaScript links, external images, embeds, wiki links, Mermaid diagrams, huge code blocks, or formulas crafted to consume resources. A conventional web renderer could execute content or make implicit requests.

Remediation: Markdown preview is capped at 2 MiB, accepts UTF-8 without NULs, parses away from the main UI path with bounded cancellation checks, and publishes results only while its generation is current. Published state does not additionally retain the original and compatibility-transformed strings. RelayBar uses a native Markdown view rather than a web view. HTML-looking spans are escaped before parsing, so active tags such as `script` and `style` remain literal, selectable text and never execute even across lines or inside Markdown link labels; valid web/mail angle autolinks retain their normal link behavior. Normal block and inline image providers never load a URL. Obsidian embeds, wiki links, and inline tags become inert local states. Private wiki, tag, footnote, and math references require a random per-preview capability token, so private-looking URLs authored by the remote document cannot bypass enrichment limits. Mermaid stays selectable source and never executes. Only clicked absolute HTTP, HTTPS, and email links without credentials or raw/percent-decoded control characters reach macOS; file, data, JavaScript, relative, unknown, credential-bearing, and forged private URLs are blocked.

Syntax highlighting receives at most 64 KiB from each explicitly labelled, supported language and is limited to 128 labelled blocks per document. It runs a bundled highlight.js build in JavaScriptCore without a DOM or network bridge and falls back to plain text. Math is syntax-validated and parsed locally with a 4,096-character formula cap, a 256-formula document budget, and bounded output dimensions. Named and inline footnotes, private internal links, and embed placeholders are also count-bounded. Invalid, oversized, and aggregate-overflow content remains selectable source.

### SR-09 — Rendering dependencies add supply-chain and license risk (medium)

Adding a Markdown stack changes the earlier dependency-free application boundary and introduces bundled code and resources.

Remediation: direct and transitive packages are pinned exactly in SwiftPM and Xcode resolution files. The selected versions preserve RelayBar's macOS 13 target. Required license notices are copied into the app bundle. MarkdownUI's default network image providers are replaced. The Xcode build retains Highlighter's formatter and the two selected themes plus SwiftMath's selected Latin Modern resources and licenses, while removing unused renderer resources from the generated app. Release builds are non-globally stripped after dSYM generation, and the executable/dSYM UUID match is verified. Dependency versions and the active-content boundary are recorded in Task 002 verification and must be reviewed before any release.

### SR-11 — Upload conflicts could replace the wrong remote entry (high)

A target can change after RelayBar asks for replacement consent, and ordinary
SFTP upload does not provide a race-safe no-overwrite publication operation.

Remediation: RelayBar uploads to a unique hidden name in the selected remote
directory. A new target is published only with the server-advertised
`hardlink@openssh.com` extension, which fails if another entry appeared. An
explicitly approved regular-file replacement requires advertised
`posix-rename@openssh.com` support. Observed directories and symbolic links,
missing capabilities, SSH-master replacement, and raced-in hard-link targets
fail closed. Cancellation and failure remove only the exact app-generated
staging path, and uncertain cleanup is reported rather than hidden.

### SR-12 — Accidental remote deletion is irreversible (high)

Single and bulk deletion now wait five seconds before any service submission,
with a visible Undo action. Closing the window or app during that interval
cancels the request. Destructive styling and separation from Download reduce
misclicks. Selection includes only presented regular files; each exact path,
kind, size, and displayed modification value is revalidated through the owned
SSH master immediately before one quoted SFTP `rm`. Batches are sequential,
with no recursion, wildcard expansion, shell, or automatic retry. Only server
acknowledgement is reported as success; unknown outcomes remain explicit.

The preflight is not an atomic identity check: a server-side writer can replace
a path after validation, and equal size/mtime cannot prove file identity.
Deletion after submission is permanent; RelayBar provides no remote trash or
post-submission recovery. Verification used isolated fake services, not live
destructive operations against a production server.

### SR-13 — JSON and media previews expand untrusted parsing (medium)

JSON retrieval and decoding enforce a 2 MiB limit, validate UTF-8, reject NULs,
and render only native selectable text; strings and URLs are never executed or
resolved. MP4 retrieval is capped at 512 MiB and stored in a private temporary
directory. AVFoundation must find a playable asset with a video track before
AVKit receives the local URL. Playback starts paused. Cancellation and preview
generations prevent stale publication, and exit clears the player and temporary
bytes. Native JSON and media parsers remain part of the trusted computing base.

## Positive controls verified

- Executable paths are fixed to `/usr/bin/ssh` and `/usr/bin/sftp`.
- Arguments are passed through `Process` as an array; there is no shell expansion.
- SSH is non-interactive and uses `BatchMode`, a connection timeout, forward-failure detection, and keepalives.
- Automatic retries are bounded by a saved 0–100 limit and exponential delays
  from 5 seconds to 5 minutes. Brief reconnects retain their retry budget;
  setting the limit to zero cancels pending retries. This reduces connection
  bursts but cannot guarantee compliance with every server's rate limits.
- One private master owns each forwarding profile; visible rules are installed with bounded, time-limited control operations and all-or-nothing startup.
- Standard input and output are closed where unused; master and control diagnostics are bounded.
- Detached SSH (`-f`) is discarded, and tracked children are terminated on stop and app quit.
- Tunnel definitions contain no passwords and remain in local application preferences.
- RelayBar locally persists at most 16 normalized recent folder paths with
  their bounded SSH connection identities. Directory listings, remote file
  names, file content, transfer state, and capability diagnostics are not
  persisted. RelayBar does not read or copy private-key contents.
- Remote Files revalidates saved connection arguments and translates SSH port/login flags to SFTP semantics without accepting new user-controlled option classes.
- There are no analytics, advertising, telemetry, tracking, account, or
  downloaded-code SDKs. The exact-pinned Sparkle framework checks only the
  signed HTTPS appcast, sends no system-profile fields, and cannot download or
  install updates automatically.
- Markdown rendering dependencies are exact-pinned and their notices are bundled. None replaces the system SSH/SFTP transport.
- The only reusable GitHub Actions step is the official checkout action, pinned to an immutable commit.
- Release builds use the hardened runtime and a Developer ID Application signature.
- Repository secret scans found no credentials, private keys, tokens, or signing material.

## Residual risks and release checks

- SSH host aliases and imported identity paths can reveal infrastructure metadata to anyone with access to the user's macOS account. RelayBar does not claim encrypted-at-rest storage.
- A deliberately non-loopback bind exposes the local listener to the selected interface. RelayBar warns but honors an explicitly imported bind.
- A Local SOCKS client may delegate hostnames to the SSH server or resolve them locally; RelayBar cannot force client DNS behavior and OpenSSH forwarding is not a UDP or general DNS proxy.
- Remote forwarding exposes Mac-side destinations to clients that can reach the server listener. Non-loopback remote binds depend on server `GatewayPorts`.
- Remote SOCKS allows server-side clients to request TCP connections from the Mac's network position, subject to the displayed `PermitRemoteOpen` policy. Listener creation does not guarantee later destination connectivity.
- Remote Unix listener replacement and cleanup are controlled by the SSH server. RelayBar reports configuration and OpenSSH results but cannot prove a remote pathname was removed.
- RelayBar is intentionally unsandboxed so system SSH can use the same `~/.ssh/config`, `known_hosts`, agent, and identity files as Terminal. Consequently, a trusted SSH configuration may use advanced OpenSSH features—including command-capable directives—that RelayBar's pasted-command importer itself rejects.
- Authentication security, host-key policy, configured SSH directives, and the remote SSH server remain the user's responsibility.
- Recursive folder downloads have no preflight total-size guarantee; the user chooses the destination, sees transferred bytes, and can cancel.
- SFTP long-list output is parsed from OpenSSH's human-readable format. Unsupported filesystem object types and unsafe names are omitted rather than guessed.
- The Markdown compatibility layer intentionally does not reproduce every Obsidian vault feature. Wiki links, tags, embeds, and Mermaid are inert, and highlight emphasis is not pixel-identical to Obsidian.
- HighlighterSwift evaluates its bundled highlight.js formatter locally. The input and language are bounded, but a defect in that third-party parser remains a residual in-process availability risk.
- Opening a permitted external link hands it to the user's browser or mail app, which may contact the destination and disclose normal request metadata. RelayBar does so only after an explicit click.
- New rendering dependency releases are not adopted automatically. Each update requires compatibility, license, security, and regression review.
- Developer ID signing does not replace notarization. A downloaded build must be notarized and stapled before Gatekeeper will accept it without publisher warnings.
