# SSH Command Import

Quick Add converts an existing SSH command into one RelayBar tunnel.

## Accepted shape

`ssh [allowed options] -L [bind:]localPort:destinationHost:destinationPort sshHost`

## Contract

- Quoted and escaped arguments are tokenized without invoking a shell.
- Exactly one local forward is required.
- Management flags `-N`, `-T`, `-n`, and `-f` are discarded; RelayBar supplies safe process behavior.
- A restricted set of connection flags and options is preserved.
- Remote commands, dynamic forwards, custom config files, and command-execution options are rejected.
- The same safety policy is checked again immediately before launch.

See [Security boundaries](../shared/security-boundaries.md).
