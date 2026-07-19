# Tunnel Management

Each saved item represents one SSH local (`-L`) port forward.

## Contract

- Users can add, edit, delete, start, and stop tunnels.
- The editor accepts a name, SSH host, local port, destination host, and destination port.
- Imported bind addresses and allowed SSH arguments are preserved.
- Editing an active tunnel stops it before replacing its definition.
- Deleting a tunnel cancels its process, retry, and pending browser launch.
- Tunnel definitions persist immediately after add, edit, or delete.

See [Data and state](../shared/data-and-state.md) for the stored schema.
