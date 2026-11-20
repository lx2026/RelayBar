# Task 089: The same folders, image details and error wording in every app

Status: Complete
Ledger: [UX parity](../../system-specs/shared/ux-parity.md)
Depends on: Task 088

## Outcome

The seven ledger rows still marked To fix are closed: folders are ordered and hide dot-entries the same way, an image shows the same details under the same labels, and the same connection failure reads the same in RelayBar, Frame and the mobile app.

## Delivery Boundary

Included: `Packages/AppComposition`, `Apps/RelayBar`, `Apps/Frame`, `Apps/RelayBarMobile`, the ledger and `scripts/parity.py`.

Excluded: new file types, layout changes beyond the hidden-entries row, the transport, stored data formats, the bridge wire format, release versions and build numbers.

## Work

1. **Folder order.** One shared rule orders a folder: folders first, then newest first within each group, with name as the tie-break. It is the default in every app. An order the person has already chosen is kept, and every app that offers a choice still offers name order.
2. **Hidden entries.** One shared rule splits a listing into shown entries and a count of names that begin with a dot. RelayBar's Remote Files and Frame, for local and remote folders, leave them out and end the list with one row giving the count and Show, which reveals them in that folder until it is left, as the mobile app does. The wording of that row is defined once.
3. **PNG text.** One Swift reader in the shared package reads `tEXt`, `zTXt` and `iTXt` chunks, compressed or not, for Frame and the mobile app; their own readers are deleted. Frame's wrong result for compressed chunks goes with its reader. A decompressed chunk is at most 1 MiB and the chunks of one image at most 2 MiB together, in the Swift reader and in the remote helper, from one definition.
4. **Image details.** One shared interpreter turns an image's raw text and camera fields into labelled details in a fixed order: prompt, negative prompt, generation settings, then camera fields. Frame's interpreter is the starting point. Frame and the mobile app show its result, and a node graph is never shown as the prompt.
5. **Connection failures.** One shared table gives each cause a title and a recovery line: host key changed, host key not trusted, sign-in refused, host not found, connection refused, timed out, and connection lost. RelayBar and the mobile app map their errors to it, and Frame shows what RelayBar reports through it. A changed key stays distinct from an untrusted one.
6. **Outline.** If Frame's document outline does not mark the section being read while the mobile app's does, add the row and close it with a shared rule for which heading is current.
7. **Fixtures.** Shared fixture cases, run by the Mac and mobile tests alike, cover folder order, the hidden split, PNG text in each chunk form including an oversized one, image details for the common generators and a camera photo, and each connection cause. The helper's tests read the same PNG fixtures.
8. **Ledger and specs.** Mark the closed rows Same, update the inventory and the counting script if needed, update the affected system specs, and add the visible changes to the unreleased notes.

## Acceptance

- `./scripts/test.sh parity` reports no rows to fix and at most 8 definitions outside the shared package, with every fixture case run on both sides.
- The same folder holding dot-entries lists them in none of the three apps until Show is used, and each app reports the same count.
- A PNG with a compressed text chunk shows the same prompt in Frame, in Frame through RelayBar, and in the mobile app.
- A refused connection and a changed host key each show the same title and recovery line in RelayBar and the mobile app.
- A folder order chosen before the change is still in effect after it.
- `./scripts/test.sh all` passes with warnings as errors, the mobile app builds for the iOS SDK, the mobile gallery is regenerated where a screen changed, and `git diff --check` is clean.
