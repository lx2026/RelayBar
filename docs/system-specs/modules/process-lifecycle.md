# Process Lifecycle

`TunnelStore` runs one long-lived `/usr/bin/ssh` multiplexing master per active profile and installs its visible rules through bounded control operations.

## Launch

- The master runs with `-N`, `-T`, `BatchMode`, a 10-second connect timeout, forward-failure exit, server keepalives, `ControlPersist=no`, and `ClearAllForwardings=yes`.
- Its private control socket is created below a random app-owned `0700` temporary directory and is not shared with unrelated SSH clients.
- The master starts with no forwards. Each rule is installed in order by direct `/usr/bin/ssh -F none -S <socket> -O forward` arguments.
- Control stdout and stderr are capped at 64 KiB and each helper times out after 10 seconds.
- Each launch carries a generation identifier, and every control operation is keyed by its own identifier and tagged with the launch that owns it. A stopped or replaced launch's operation can neither block nor complete the launch that replaced it, so a restart issued while a previous helper is still being reaped installs its rules normally.
- A helper's pipe handlers are detached before its remaining output is read, so one reader owns each descriptor. Output delivered after an operation completes is discarded rather than carried into the next operation.
- A profile stays Starting until every rule succeeds. Any failure or timeout terminates the master and removes all forwards rather than publishing a partially running profile.
- For each remote TCP port-`0` rule, the helper's numeric stdout is associated with that stable rule UUID. Non-numeric or ambiguous output fails startup.
- Master standard input and output are discarded; the last 16 KiB of standard error is retained for status messages.
- Local Unix listeners are preflighted before launch. RelayBar records the device and inode of sockets created by its rules and removes only a still-matching socket during cleanup.

## Recovery

- Unexpected exits and startup failures use the global Settings retry limit:
  0–100 retries after the initial attempt, defaulting to 10. A limit of 0
  disables automatic retries and leaves a failure requiring an explicit start.
- Delays are 5, 10, 20, 40, 80, 160, then 300 seconds for remaining attempts.
  Delays apply independently per profile and start after the previous failure;
  this is not a server-wide connection rate limit across profiles or apps.
- A connection must remain fully running for at least 60 continuous seconds
  before its next failure receives a fresh retry budget and initial delay.
  Elapsed time uses a monotonic clock. Brief reconnects retain both the count
  and backoff; an explicit new start resets them immediately.
- Retry-limit changes persist immediately. A pending retry above the new limit
  is cancelled, including every pending retry when set to 0. Allowed pending
  retries keep their existing deadline and display the new limit. Changing the
  limit does not stop a running or starting connection, replenish its count,
  or restart an exhausted or stopped profile.
- Each retry creates a new control directory and clears prior runtime port allocations.
- Stop, edit, delete, and quit terminate the master and every helper owned by that profile, cancel startup and pending retries, and clean owned sockets and control files.
- Group-only edits and group move, rename, or ungroup actions do not stop or launch SSH. They preserve stopped, starting, retrying, running, or failed phase and all process-owned runtime state.
- Group Start All, Stop All, and Restart All snapshot the group's saved members at invocation and reuse the per-profile start and stop paths unchanged — including retry, generation, cleanup, and error behavior — so each member's outcome is independent and no second process manager or group runtime state exists.
- Exhaustion changes the profile to failed and requires another user start.

Phases are `stopped`, `starting`, `retrying`, `running`, and `failed`.

## Remote Files session

- Each Remote Files window owns at most one foreground `/usr/bin/ssh` multiplexing master for its active exact connection identity. This process is separate from every forwarding-profile master and has no forwarding rules.
- Its one-character control socket lives in a short, atomically created `0700` directory below the user's private macOS temporary directory. The path budget reserves both Darwin's terminating NUL and OpenSSH's 17-byte temporary mux-listener suffix.
- Concurrent initial SFTP operations wait on one serialized startup. The private control socket is considered ready only after it appears while the owned process is still running, with a 120-second bounded readiness ceiling. Cancelling one waiter resumes it immediately without disrupting the shared startup for other or later work.
- Listings, previews, downloads, upload staging measurements, publication,
  cleanup, deletion preflight, and deletion remain independent, bounded
  `/usr/bin/sftp` children. Cancelling or reaping one child does not signal the
  master.
- Master exit removes its socket and temporary directory. There is no retry timer or background reconnect; a later explicit operation starts a replacement master.
- Server change and Back-to-welcome retire the active session and snapshots.
  Window close cancels visible work; when an upload owns a remote staging name
  or a deletion may have been submitted, the model remains retained until its
  bounded child is reaped and the master is shut down. App termination uses
  AppKit's deferred reply to wait for that retirement instead of orphaning the
  master, abandoning known staging, or claiming a deletion result it did not
  receive.
- Replacing or closing an MP4 preview pauses and clears its `AVPlayer`, cancels
  the owned retrieval or validation task, rejects late generation callbacks,
  and removes its app-owned private temporary file before session retirement.
