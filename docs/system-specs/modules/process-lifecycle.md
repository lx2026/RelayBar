# Process Lifecycle

`TunnelStore` runs one `/usr/bin/ssh` child process per active tunnel.

## Launch

- SSH runs non-interactively with `BatchMode`, a 10-second connect timeout, forward-failure exit, and server keepalives.
- Standard input and output are discarded; the last 16 KiB of standard error is retained for status messages.
- A process still alive after 450 ms is presented as running.

## Recovery

- Unexpected exits retry up to 10 times.
- Delays are 1, 2, 4, 8, 16, 32, then 60 seconds for remaining attempts.
- A successful connection resets the retry count.
- Stop, edit, delete, and quit cancel pending retries.
- Exhaustion changes the tunnel to failed and requires another user start.

Phases are `stopped`, `starting`, `retrying`, `running`, and `failed`.
