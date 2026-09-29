# Task 045 — Configurable SSH Retries

Status: Complete

Created: 2026-09-28

Completed: 2026-09-28

Evidence: [Verification report](../../verification/045-configurable-ssh-retries.md)

Issue: [#30](https://github.com/lx2026/RelayBar/issues/30)

## Outcome

Reduce repeated SSH connection attempts during outages and let people limit or
disable automatic retries in Settings.

## Delivery Boundary

Applies globally to forwarding profiles. Remote Files retains its explicit
operation-driven reconnect behavior. No release or deployment is included.

## Work

- Persist a retry limit from 0–100, defaulting to 10; 0 disables retries.
- Back off for 5, 10, 20, 40, 80, 160, then 300 seconds between attempts.
- Retain the count across short-lived connections; reset after 60 seconds
  continuously running or an explicit new start.
- Apply limit changes to pending retries immediately without stopping running
  connections or starting stopped or exhausted profiles.
- Cover persistence, exact attempt counts, connection flapping, stable recovery,
  limit changes, cancellation, and Settings layout; update system documentation.

## Acceptance

- Settings saves the limit across store recreation, explains 0 and backoff,
  and fits the standard popover in light and dark appearances.
- An initial attempt plus exactly the configured retries exhausts the budget;
  0 performs only the user-initiated attempt. Pending retries obey lower limits.
- Delays increase and cap as specified; brief reconnects retain the budget and
  stable connections and manual restarts reset it. Stop cancels pending retries.
- Relevant automated tests, strict-concurrency app build, visual evidence,
  system specs, and `git diff --check` pass. No production SSH target is used
  to induce failures; any live verification not performed is recorded.
