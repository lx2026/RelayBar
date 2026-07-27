# Task 024 — Group Lifecycle Actions

Status: Complete

Created: 2026-07-26

Issue: [#11 — Add an option to stop/start/restart all connections in a group](https://github.com/lx2026/RelayBar/issues/11)

## Outcome

Let users start, stop, or restart the applicable forwarding profiles in one
named group from that group's existing menu.

## Delivery Boundary

- Add **Start All**, **Stop All**, and **Restart All** to named group menus.
- **Start All** starts safe group members that are not active and leaves active
  members unchanged.
- **Stop All** stops starting, running, and retrying members and leaves stopped
  members unchanged.
- **Restart All** restarts the members that are starting, running, or retrying
  when the action begins; it does not start stopped members.
- Snapshot target profile IDs when an action begins and isolate every action to
  that group. Do not affect ungrouped profiles or another named group.
- Reuse the existing per-profile lifecycle, retry, generation, cleanup, and
  error behavior; do not introduce a second process manager or group runtime
  state.

## Work

- Add group-scoped store operations that resolve current saved profiles by
  canonical group identity and apply the existing lifecycle operations.
- Preserve independent outcomes: one invalid or failed profile must not prevent
  eligible peers from being started, stopped, or restarted.
- Make restart use the current saved profile definition and preserve the
  superseded-launch protections already used by individual profile lifecycle
  operations.
- Add the three commands above the existing rename and ungroup commands with
  state-aware enablement, separators, keyboard access, and VoiceOver labels.
- Add focused store and UI tests covering mixed phases, partial failure,
  canonical group matching, group isolation, and membership changes.
- Update tunnel-management, process-lifecycle, and verification system specs.

## Acceptance

- A named group menu exposes **Start All**, **Stop All**, and **Restart All**
  without changing the row controls or the ungrouped header.
- **Start All** starts each safe inactive member once and does not relaunch an
  already starting, running, or retrying member.
- **Stop All** cancels startup, retries, browser work, control operations, and
  owned SSH processes for every active target in the group.
- **Restart All** replaces each member active at invocation with one fresh
  launch and does not start members that were stopped.
- Batch actions never target a profile outside the selected canonical group,
  even when group names differ only by case or harmless whitespace.
- Failure of one member remains visible on that row and does not block the
  other targets.
- Rename, ungroup, move, edit, delete, per-row start/stop, and application-wide
  quit behavior remain unchanged.
- Mixed stopped, starting, running, retrying, and failed fixtures render and
  behave correctly at 380 × 440 points in light and dark appearances.
- Focused tests, `swift test -Xswiftc -warnings-as-errors`, the Release build,
  and `git diff --check` pass.
- No release or deployment occurs without separate approval.

## Evidence (2026-07-26)

- `TunnelStore.startGroup`, `stopGroup`, and `restartGroup` snapshot saved
  members by canonical group identity at invocation and reuse the existing
  per-profile lifecycle; no second process manager or group runtime state was
  added. The named-group menu offers the three commands above rename and
  ungroup with a separator, state-aware enablement, and VoiceOver labels.
- Six focused store tests cover mixed phases, repeated batch starts, partial
  rule failure, failed-member phase preservation, canonical case/whitespace
  matching from decoded data, group isolation, and membership snapshots at
  invocation; each ran clean three times in a row.
- `swift test -Xswiftc -warnings-as-errors` (180 tests), the Xcode Release
  build (strict concurrency, warnings as errors), and `git diff --check` pass.
  Row controls, ungrouped header, and quit behavior are untouched by the
  change and covered by the existing suites.
- The user manually tested the installed Developer-ID-signed, Apple-notarized
  build and confirmed the group lifecycle issue is fixed. A second explicitly
  approved notarized build was then accepted, stapled, and Gatekeeper-verified
  before pull-request preparation.
