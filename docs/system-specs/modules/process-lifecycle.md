# Process Lifecycle

`TunnelStore` owns saved profiles, grouping, aggregate presentation and, as the single owner, one `TunnelProfileRuntime` per instantiated profile with that profile's long-lived `/usr/bin/ssh` master, startup and retry work, control operations and retiring children. Start launches at once; Stop cancels at once. Work and reaping tasks live in separate effect scopes so cancellation cannot discard the force-kill deadline needed to finish cleanup. The store itself is owned by the app's `tunnels` feature, which closes command admission when it is withdrawn and awaits the store's shutdown. Profiles and groups are data, not features.

## Launch

- The master runs with `-N`, `-T`, `BatchMode`, a 10-second connect timeout, forward-failure exit, server keepalives, `ControlPersist=no`, and `ClearAllForwardings=yes`.
- Its private control socket is created below a random app-owned `0700` temporary directory and is not shared with unrelated SSH clients.
- The master starts with no forwards. Each rule is installed in order by direct `/usr/bin/ssh -F none -S <socket> -O forward` arguments.
- Control stdout and stderr are capped at 64 KiB and each helper times out after 10 seconds.
- Each launch carries a generation identifier, and every control operation is keyed by its own identifier and tagged with the launch that owns it. A stopped or replaced launch's operation can neither block nor complete the launch that replaced it, so a restart issued while a previous helper is still being reaped installs its rules normally.
- A helper's pipe handlers are detached before its remaining output is read, so one reader owns each descriptor. Output delivered after an operation completes is discarded rather than carried into the next operation.
- Master stderr callbacks also check their launch generation. Late output from a replaced master cannot contaminate its successor's error message.
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
- Stopping, timing out or cancelling a control command uses the same bounded reaping path as the master. A child that ignores TERM receives KILL after the grace period; repeated stop requests do not postpone that deadline. Deleting and re-adding a profile keeps its retired runtime separate from the new instance until cleanup completes.
- Terminal store shutdown closes command admission and drains every profile, including deleted profiles and superseded startup tasks. A retained store cannot launch SSH, open a browser or rewrite saved profiles after its composition feature has been withdrawn.
- Group-only edits and group move, rename, or ungroup actions do not stop or launch SSH. They preserve stopped, starting, retrying, running, or failed phase and all process-owned runtime state.
- Group Start All, Stop All, and Restart All snapshot saved membership and apply to those profiles in one main-actor turn. Restart stops and starts only the active members. Inactive or failed peers retain their state, and tag edits never restart a profile.
- Exhaustion changes the profile to failed and requires another user start.
- Reconnect on Wake (a plugin, on by default): when the Mac wakes, or the network path becomes satisfied after it was not, every profile that is waiting on a retry delay makes that attempt now. It is the same attempt, with the same number and the same remaining budget, under the same checks the waiting retry would have applied. Stopped, failed, exhausted, starting and running profiles are untouched, and nothing happens after the store's command admission has closed. Events inside a two-second window cause one retry. With the plugin off, delays run to their end as described above. Its notification observer, path monitor and pending wait belong to the plugin's feature and end when it is switched off or the app quits.
- Browser opening uses the opener the store was created with. A store whose feature has been withdrawn opens nothing.

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
  Window close cancels and drains all owned directory, download, preview, upload
  and deletion work, including superseded tasks still cleaning up. The model
  remains retained until bounded children and every retiring master are reaped
  and private control directories are removed. App termination uses
  AppKit's deferred reply to wait for that retirement instead of orphaning the
  master, abandoning known staging, or claiming a deletion result it did not
  receive.
- Replacing or closing an MP4 preview pauses and clears its `AVPlayer`, cancels
  the owned retrieval or validation task, rejects late generation callbacks,
  and removes its app-owned private temporary file before session retirement.
