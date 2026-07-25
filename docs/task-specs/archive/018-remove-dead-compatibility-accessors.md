# Task 018 — Remove Dead Compatibility Accessors

Status: Complete

Created: 2026-07-24

Completed: 2026-07-25

## Outcome

`Tunnel`'s compatibility accessors are commented as keeping Remote Files and legacy callers source-compatible, but Remote Files now consumes `RemoteServer`. Of that block only `destinationEndpoint` still has a caller. `localPort`, `destinationHost`, `destinationPort`, `bindAddress`, `forwardSpec`, and `localEndpoint` have no callers in `Sources/`, and neither do `forwardArguments` or `usesUnixSockets`.

`browserURL` is a pure alias for `unambiguousBrowserURL` with no source caller; its only references are tests, which therefore exercise an alias the app never uses. `SSHCommandParser.ImportedTunnel` carries the same unused set.

## Delivery Boundary

### Included

- Accessors with no remaining caller in `Sources/`.
- Test references that exist only to cover a removed alias, redirected to the surviving property.

### Excluded

- `destinationEndpoint`, which `RemoteServer` still uses.
- The `CodingKeys` entries for `localPort`, `destinationHost`, `destinationPort`, and `bindAddress`. Those decode legacy v1 records and must stay.

## Work

- Remove the unused accessors from `Tunnel` and `ImportedTunnel`.
- Point the `browserURL` tests at `unambiguousBrowserURL` so the covered surface is the one the app calls.
- Leave legacy decoding, its keys, and its tests untouched.

## Acceptance

- The app builds with no reference to a removed accessor.
- Legacy v1 records still decode, and their tests pass unchanged.
- Browser-URL behavior stays covered through the property the app actually uses.
- `swift test` and `git diff --check` pass.

Completion evidence is recorded in [Tasks 005–019 verification](../../verification/005-019-audit-remediation.md).
