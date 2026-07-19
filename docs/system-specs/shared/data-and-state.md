# Data and State

## Persisted tunnel

`Tunnel` stores: UUID, name, local port, destination host and port, SSH host, optional bind address, and preserved SSH arguments.

- Storage: JSON array in `UserDefaults` under `savedTunnels.v1`.
- Missing `additionalArguments` decode as an empty array for compatibility.
- Runtime phase, processes, errors, retries, and browser requests are not persisted.

## Runtime ownership

`TunnelStore` is main-actor isolated and publishes saved tunnels plus phase by UUID. It separately tracks:

- desired active tunnels;
- child processes and stderr buffers;
- retry attempts and scheduled tasks;
- pending browser URLs.

The desired-active state lets a retrying tunnel remain stoppable while no process exists.
