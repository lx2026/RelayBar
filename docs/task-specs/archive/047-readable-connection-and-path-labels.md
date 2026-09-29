# Task 047 — Readable Connection and Path Labels

Status: Complete

Created: 2026-09-28

Completed: 2026-09-28

Evidence: [Verification](../../verification/046-048-remote-files-and-editor-usability.md)

## Outcome

Keep the distinguishing destination, folder name, and host information readable
in the tunnel list and narrow Remote Files workspace.

## Delivery Boundary

Display changes only: preserve full endpoint values, paths, connection identity,
copy actions, keyboard navigation, and accessibility information.

## Work

- Compact default-loopback endpoint summaries without changing SSH arguments.
- Avoid repeating a host prefix for single-host recents; separate host identity
  and folder path for multiple hosts and retain path suffixes under truncation.
- Use icon-only toolbar actions at narrow widths before squeezing path text.

## Acceptance

- Destination ports and final folder names remain visible in representative
  long/narrow captures; non-loopback and IPv6 endpoints remain unambiguous.
- Full values remain available to help/accessibility and copy operations.
- Relevant tests, light/dark visual checks, system specs, and diff checks pass.
