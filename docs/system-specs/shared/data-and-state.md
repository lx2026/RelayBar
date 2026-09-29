# Data and State

## Persisted forwarding profile

`Tunnel` stores a stable UUID, name, optional group tag, SSH destination, allowed connection arguments, ordered typed forwarding rules, optional Remote SOCKS policy, and Unix-socket settings. Each rule has a stable UUID, explicit kind, tagged TCP-or-Unix listener, and an optional tagged fixed destination.

- Storage: JSON array in `UserDefaults` under `savedTunnels.v2`.
- A group tag is either absent or a normalized string of at most 32 user-visible characters. Normalization trims surrounding whitespace and collapses internal whitespace runs. Line breaks and control characters are invalid.
- Group matching uses a locale-independent case-folded key and retains the first saved spelling. Groups are derived from profile tags; there is no separate group collection, empty-group record, index, or cache.
- Section derivation buckets profiles in one pass, sorts only distinct named groups with localized standard ordering, preserves profile order inside each bucket, and appends Ungrouped last.
- When v2 is absent, the entire `savedTunnels.v1` array must decode before each legacy tunnel is converted to one equivalent Local TCP rule and the v2 collection is written. The legacy value is retained.
- Legacy UUID, name, optional group tag, SSH host, bind, ports, destination, and allowed arguments are preserved. Missing `groupTag` decodes as ungrouped, and missing `additionalArguments` still decodes as an empty array.
- Runtime phase, processes, errors, retries, control paths, browser requests, owned-socket identities, and allocated remote ports are not persisted.

## Runtime ownership

The global forwarding retry limit is stored separately from profiles as an
integer in `UserDefaults` under `sshRetryLimit.v1`. Missing or non-integer
values default to 10; integer values are clamped to 0–100, preserving 0 as
disabled. Settings writes through `TunnelStore.setMaxRetryAttempts` so active
retry waits immediately observe the policy change. Attempts, deadlines, and
monotonic connection-start times remain runtime-only.

`TunnelStore` is main-actor isolated and publishes saved tunnels plus phase by UUID. It separately tracks:

- desired active profiles;
- master and control processes plus bounded output buffers;
- retry attempts and scheduled tasks;
- pending browser URLs.
- allocated remote ports by profile UUID and rule UUID;
- private control locations and app-owned local socket identities.

The desired-active state lets a retrying profile remain stoppable while no process exists. A metadata-only group mutation updates both the saved and desired-active profile copies without replacing any runtime state. Remote Files derives saved SSH connections from profile-level host and argument data and continues deduplicating equivalent connections regardless of rule count or group tag.

## Remote Files server catalog

- Standalone Remote Files hosts are JSON records in `UserDefaults` under `remoteFiles.savedServers.v1`. Each stores a stable UUID, bounded display name, validated SSH host, and safe connection arguments. The collection is capped at 128 records.
- Successful Remote Files connections are JSON records under `remoteFiles.recentServers.v1`. The newest connection is first, equivalent connections collapse by SSH host and arguments, and the collection is capped at eight records.
- Successful Remote Files roots are JSON records under
  `remoteFiles.recentLocations.v1`. Each stores a stable UUID, normalized
  absolute path, exact SSH connection identity, and bounded host display
  metadata. Equivalent connection-and-path pairs collapse and move to the
  front, direct-file opens record their parent, and the collection is capped at
  16. Failed, cancelled, or superseded opens are not recorded.
- Location history stores no listing, listed file name, remote bytes,
  credential, connection state, or upload state. Removing one location, clearing
  all locations, or removing a standalone host changes only the matching local
  records; forwarding profiles and OpenSSH config remain unchanged.
- Forwarding profiles and concrete aliases discovered from `~/.ssh/config` remain external inputs to the catalog. Config aliases are read on refresh and are not persisted as standalone RelayBar hosts.
- Remote Files directory snapshots are session-only. They are keyed by exact connection identity and normalized path, bounded by aggregate entry units, and cleared on session end; no listing or downloaded content enters `UserDefaults`.
- Image, Markdown, JSON, and MP4 preview content, upload and video-retrieval byte measurements, deletion
  fingerprints, outcomes, and accessibility announcements are session-only.
  RelayBar persists no preview body, transfer history, deletion history, remote
  filename, or deletion telemetry.
- The pending-deletion deadline and task exist only in memory. Undo invalidates
  the task generation and cancels its five-second wait; it never persists a
  queue or restores a file after server submission.
- The combined picker order is recent, standalone saved host, forwarding profile, then OpenSSH config. The first connection at each SSH-host-and-arguments identity wins.
