# Security Policy

## Supported versions

Security fixes are provided for the latest released version of RelayBar.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature for this repository. Do not include private keys, passwords, production hostnames, or other secrets in a report. If private reporting is unavailable, open an issue that contains no sensitive details and request a private contact channel.

RelayBar's security boundary is intentionally narrow: it invokes `/usr/bin/ssh` directly with a fixed executable path and structured arguments, never through a shell. Imported options capable of executing local commands or selecting arbitrary configuration files are rejected. See [the security review](docs/SECURITY_REVIEW.md) for the current threat model and residual risks.
