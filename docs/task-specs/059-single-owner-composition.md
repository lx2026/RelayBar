# Single-owner composition kernel

Status: In progress — 2026-11-13

## Outcome

Replace the Task 058 composition kernel with the second design from the composition audit. Every lifetime has one owner: the feature tree is a pure function of state, features declare needs and offers as stored properties, availability that changes at run time flows through slots, each feature transitions independently within a deadline, and the shells read typed ports. Hand-written second copies of lifecycle state are removed. The bridge then moves to one connection per session.

## Delivery Boundary

- Builds on the uncommitted Task 058 working tree on `codex/task-058-composition`. Pre-task snapshot: `.build/task-059-baseline/`.
- Supersedes Task 058 where they conflict: per-profile lifecycle entries, group loader entries, the persisted feature tree and its migrations, typed events, per-call policy metadata, and the requirement that every feature resolve through the kernel. Task 058 keeps its monorepo, distribution, native and live-host acceptance.
- A feature boundary exists only where something varies independently: a user switch, availability that comes and goes, or a second realm. Everything else is a plain object owned by an effect scope inside a feature.
- Preserve both apps' identities, data locations, stored profiles, bookmarks, favourites, history and grants; provider-side authorization; and the [process-lifecycle contract](../system-specs/modules/process-lifecycle.md) guarantees (generation protection, retry budgets, bounded reaping, deferred termination).
- The unreleased `features.json` is neither read nor migrated. Preferences import once from the legacy UserDefaults keys.
- Frame has no public release, so wire v7 replaces v6 without a dual stack; a v6 peer gets the existing incompatible-version outcome.
- Excluded: unifying the two apps' preview renderers, release-version changes, and any push or publication.

## Work

1. **Kernel.** Add the new kernel beside the old one in `Packages/AppComposition`: type-named service keys; `Feature` values whose `@Need`/`@Offer` properties are the contract and whose other properties are configuration; a result-builder tree with realms; a synchronous, coalescing `set(tree)`; per-feature load and cleanup tasks with dependents-first ordering; slots that can be filled and cleared while active; labelled effects; a cleanup deadline that reports and contains a stuck feature; retry only when a failure's inputs change or on request; pending and failure reasons; typed observable ports. Reject invalid trees without disturbing the active one. Port the existing kernel tests and add the audit's eight probes as tests.
2. **Preferences.** One typed, versioned preference document per app, saved atomically with a previous-version backup before anything is applied. Settings that tune a live service are small features whose configuration is the setting.
3. **RelayBar.** Rebuild the composition root on the new kernel. Tunnels are one feature; profiles are owned by the store's scopes, without projection, revisions or a second activation path. Browser opening and the server catalog are injected values. Remote Files is present while its window is open, with one child per enabled preview format. Remove the nested preview runtime.
4. **Frame link.** One feature owns discovery and the session and offers the authenticated capabilities through a slot. Remove outside activation, the separate transition queue and the marker features.
5. **Frame tree.** Mount preview, playback, metadata and file-action features once per realm (local, remote) against shared keys; the remote realm depends on the session. Merge features that always live and die together.
6. **Shells.** Both shells read ports; remove hand-assigned mirrors, name-based context lookups and generation polling. Surface pending and failed reasons to the user. App termination uses a bounded shutdown that reports what did not finish.
7. **Bridge v7.** One authenticated connection per session with typed, multiplexed requests, pushed progress and events. Peer identity is verified once per connection. Jobs belong to their connection and are cancelled when it closes. End of connection withdraws the session.
8. **Remove the first kernel**, its fixtures and tests; keep one module name for the kernel; update the system specs and the adding-a-feature guide.

## Acceptance

- The eight probe behaviours hold as tests: unrelated features do not wait on a slow load or cleanup; independent cleanups overlap; a cleanup that never returns is reported by name and cannot block other features or shutdown; failure is retried on changed inputs or on request; rapid tree changes coalesce; a failed save activates nothing; an undeclared dependency cannot be expressed.
- No `features.json` feature identifiers are persisted. A preference file from a newer version is preserved and never applied. Legacy UserDefaults values import once.
- Starting, stopping, restarting and editing tunnels behave as the process-lifecycle contract describes, with one owner per profile; starting a tunnel never waits on another feature.
- Frame's remote features load when the session slot fills and unload when it clears, for quit, revoke, hidden folders, incompatibility and transport loss; local features are unaffected; no result or permission survives withdrawal; reconnection never replays an uncertain mutation.
- Each preview, playback and remote-capability consumer is defined once; no marker features, `setActive`, name-based context lookups or mirror assignments remain.
- With wire v7, ending either process withdraws the session in the other without polling and cancels its jobs; existing bridge security assertions remain covered.
- Hand-written lifecycle guard counts (generation comparisons, closing/stopping flags, change relays) are at or below the Task 058 baseline snapshot.
- `scripts/test.sh` passes with warnings as errors; both apps build; `git diff --check` passes; affected system specs and a verification record are updated. Native, signed and live-host evidence stays with Task 058.
