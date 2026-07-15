# RelayBar security review

Review date: July 15, 2026

## Scope and threat model

This review covers command import, tunnel persistence, child-process management, diagnostic output, network exposure, packaged resources, and accidental secret publication. It assumes an attacker may provide a crafted command for a user to paste or tamper with RelayBar's preferences, but does not treat a fully compromised local macOS account as a boundary RelayBar can defend.

## Findings remediated

### SR-01 — Unsafe OpenSSH options could execute local commands (high)

The initial importer preserved arbitrary `-o` values and custom `-F` configuration files. OpenSSH options such as `ProxyCommand`, `LocalCommand`, and `KnownHostsCommand` can execute local programs even though RelayBar never invokes a shell itself.

Remediation: the importer and runtime now share an allowlist. Command-executing options, custom config files, log files, control sockets, remote commands, remote forwards, and dynamic forwards are rejected. Runtime validation also protects against a tampered preferences payload.

### SR-02 — A manual SSH host could be interpreted as an option (high)

A manually entered target beginning with `-` could be parsed by OpenSSH as another option.

Remediation: SSH targets must be a single non-control, non-whitespace token and cannot begin with `-`. The same validation runs again immediately before process launch.

### SR-03 — Non-loopback bind addresses were easy to overlook (medium)

An imported `-L 0.0.0.0:...` or wildcard bind can expose a forwarded service to other machines.

Remediation: imported non-loopback binds display an explicit warning before saving. Manual creation remains loopback-only.

### SR-04 — Unbounded child-process diagnostics (low)

Long-running verbose SSH output could otherwise consume memory.

Remediation: stderr is continuously drained and capped to the most recent 16 KiB. Only the last two lines are displayed.

## Positive controls verified

- The executable path is fixed to `/usr/bin/ssh`.
- Arguments are passed through `Process` as an array; there is no shell expansion.
- SSH is non-interactive and uses `BatchMode`, a connection timeout, forward-failure detection, and keepalives.
- Standard input and output are closed; diagnostic stderr is bounded.
- Detached SSH (`-f`) is discarded, and tracked children are terminated on stop and app quit.
- Tunnel definitions contain no passwords and remain in local application preferences.
- No dependencies, analytics, network SDKs, update frameworks, or downloaded code are present.
- The only reusable GitHub Actions step is the official checkout action, pinned to an immutable commit.
- The App Store sandbox requests only outgoing network access, local-listener access required for forwards, and read-only user-selected files.
- Repository secret scans found no credentials, private keys, tokens, or signing material.

## Residual risks and release checks

- SSH host aliases and identity paths can reveal infrastructure metadata to anyone with access to the user's macOS account. RelayBar does not claim encrypted-at-rest storage.
- A deliberately non-loopback bind exposes the local listener to the selected interface. RelayBar warns but honors an explicitly imported bind.
- Authentication security, host-key policy, and the remote SSH server remain the user's responsibility.
- The first connection to a host uses trust on first use (`StrictHostKeyChecking=accept-new`); newly seen keys are saved in RelayBar's private known-hosts file, while a later key change is rejected. Users should independently verify host-key fingerprints for sensitive systems.
- The signed App Sandbox build was verified to launch system SSH, enforce sandbox file denial, and use RelayBar's private known-hosts file. Security-scoped identity selection still needs one end-to-end test on an unlocked Mac before submission; the app deliberately does not request broad access to `~/.ssh`.
- Export-compliance and App Store declarations must be confirmed by the Apple Developer account holder.
