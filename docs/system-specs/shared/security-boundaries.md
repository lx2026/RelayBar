# Security Boundaries

- RelayBar invokes `/usr/bin/ssh` directly and never invokes a shell.
- Host values cannot be empty, option-shaped, whitespace-separated, or contain control characters.
- Additional arguments must match the explicit allowlist in `SSHArgumentPolicy`.
- Options that execute commands, choose arbitrary config files, or write logs are blocked.
- SSH uses batch mode; password prompts are unsupported.
- Normal SSH configuration, known hosts, identity files, and the user's SSH agent remain available.
- Non-loopback bind addresses are called out in the editor.
- Browser launch fixes the scheme to HTTP and falls back to `localhost` when a bind host cannot form a valid URL.

Detailed threat review: [Security review](../../SECURITY_REVIEW.md).
