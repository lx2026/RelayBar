# Lines reduction

Status: Implemented — 2026-11-14. Every cut is in and the automated gate passes; no running-app pass was made. Evidence: [verification record](../verification/060-lines-reduction.md).

## Outcome

Remove the Swift that does not earn its keep, measured in lines but chosen by concept: a second owner of the same state, a layer that only forwards, a table kept in two places, a repeated shell, code nothing calls. What the apps do, show, limit and check does not change.

## Delivery Boundary

- A line counts as removed only when a concept went with it. Denser formatting, shorter names, joined statements and deleted comments are not reductions and are not allowed.
- A new helper or type is allowed only when it replaces at least three copies and the total goes down.
- No change to behaviour, UI text, limits, error messages or security checks. No assertion and no test case is removed; tests lose lines only through shared fixtures.
- The cuts below were chosen from four read-only analyses (RelayBar Remote Files and views; RelayBar process, SSH and bridge code; Frame and the kernel; the test suites), each of which had to cite the code and show the arithmetic.
- Rejected after analysis, and not to be attempted under this task:
  - One process-supervision primitive for the tunnel master, its control helpers and the Remote Files master: about 100 lines for a high risk to callback order, diagnostics and reaping. The SFTP children are not an interchangeable copy.
  - Removing bridge jobs now that calls are multiplexed: once the admission limits, transfer-directory leases, the operation deadline and "never replay an uncertain mutation" are preserved, the net is roughly zero, and it would change the wire again.
  - Typed bridge messages as a line saving: they move code.
  - Treating a single remote delete as a batch of one: it changes two edge states.
  - Merging the five preview properties of the Remote Files model into one: 15 lines for 39 edited test reads.
  - A shared "latest request wins" type in the kernel: Frame's store uses its tokens across several tasks, so only RelayBar's model benefits, and there it stays file-private.
  - Removing `MediaRemoteAccess`: it carries the rule that a withdrawn feature rejects every call, including a cache read between two calls of one operation.
- Needs the owner's decision, not part of this task:
  - Narrowing Frame's shell handle `ComposedRemoteAccess` to library and file reading (13 lines; tightens what the UI can reach, rewrites three tests).
  - API only tests use in Frame (`rememberOpen` on the library protocol, `folderChoices`, selection byte and member counts, `toggleRemoteFolder`, `RemoteFolderIndex.rows`): about 38 lines, each with test cases that would go with it.
  - RelayBar's native Markdown stack is about 3,700 lines and three dependencies, while Frame renders Markdown through WebKit in about 500. Unifying them is the largest available cut and changes RelayBar's documented Obsidian reading compatibility.

## Work

1. **RelayBar, tunnels.** Remove entry points nothing calls (`cancelBrowserOpen`, `stopAllAndWait`, the runtime's `stopAndWait`), the store's always-true `available` predicate, and the group-tag synchronisation into a launch snapshot nothing reads.
2. **RelayBar, Remote Files.**
   - One keyboard monitor in place of three identical shells.
   - Deletion: drop the `isAuthoritativeRefresh` flag and adopt a refreshed listing in one place.
   - The window controller stops co-owning the model's shutdown; the window feature is its one owner.
   - The standalone preview path stays, without its unused on/off and limit machinery; the opening protocol goes.
   - One file-private type for the model's five request tokens. Every staleness check stays.
   - One table of preview formats instead of extension sets kept in two places and five classification chains.
   - Each host's sidebar paths computed once.
3. **Frame.**
   - Remove code nothing calls: the filmstrip view and its thumbnail, the `showError` branch they alone used, two unused store entry points, an unread parameter, and three unused helpers.
   - Features that hand-write "check, owned run, check" use `FeatureContext.perform`; those that borrow no folder, write no receipt and have no user Cancel lose their private work scope.
   - `PlaybackController` keeps the one load path production uses.
   - One prologue and one failure report for the store's four file operations.
   - The kernel itself is unchanged: the analysis found nothing in it without a consumer or a test.
4. **Tests.** A model builder, an open-browser helper and a shared-SSH fixture for the Remote Files tests; the fake-SSH fixture owns its isolated defaults; one keyed gate for Frame's three entered-and-released gates. Test cases before and after must be equal.

## Acceptance

- `scripts/test.sh` passes with warnings as errors, with at least as many test cases as before in every target (RelayBar 386, Frame 164, shared 55, plus anything added by Tasks 061 and 062).
- Both apps build, including RelayBar's Xcode target; `git diff --check` passes.
- Each work item reports its net lines for production and tests, measured before and after; the verification record lists them and the total.
- A second reviewer that did not write the change reads each lane's diff for behaviour changes, and its findings are resolved or recorded.
- System specs are updated where a named type or owner changed.
