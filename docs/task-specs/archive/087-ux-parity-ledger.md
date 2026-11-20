# Task 087: A parity ledger and its numbers

Status: Complete
Depends on: Task 086

## Outcome

A behaviour a person can notice in more than one of RelayBar, Frame and the mobile app is written down once with its status, and one script reports whether the apps are converging.

Two audits found that the apps share the Markdown renderer and little else that a person sees: nine file-type tables, two copies of the reader colours, two PNG text readers, and different limits, folder order, hidden-file handling, wording and error sentences. The aim is consistency of experience, by sharing decisions where the interface code cannot be shared.

## Delivery Boundary

Included: a ledger under `docs/system-specs/shared/`, a script under `scripts/`, tests in `Apps/RelayBarMobile`, two corrections in the mobile app, and one paragraph in `AGENTS.md`.

Excluded: any change to `Apps/RelayBar` or `Apps/Frame`, and moving code into `Packages/AppComposition`. Those follow in Tasks 088 and 089.

## Work

1. **Ledger.** `docs/system-specs/shared/ux-parity.md` holds one row per behaviour a person can notice in more than one app: what each app does today, where that is decided in code, and a status of Same, Different on purpose, or To fix with the direction it will be fixed in. It starts from the two audits' findings and records these decisions, each as To fix until every app follows it:
   - folders list newest first by default;
   - names that begin with a dot are tucked into one row with Show;
   - the verb for keeping a folder, file or website is Pin, and the noun for a web service a person opens is Website;
   - JPEG and PNG open in every app, and other image formats come from one plugin that is on by default;
   - rendered Markdown uses the paper palette in every app.
2. **Numbers.** `scripts/parity.py`, run as `scripts/test.sh parity`, prints three numbers and exits non-zero only when the ledger names a file that no longer exists:
   - facts defined outside `Packages/AppComposition` that should be defined once: file-extension tables, byte and count limits, reader palette literals, PNG text readers;
   - shared fixture cases run by both a Mac test and a mobile test, over all shared fixture cases;
   - ledger rows whose status is To fix.
   The script's rules for counting each are stated in the ledger.
3. **Fixtures.** The mobile tests run every existing companion-grouping fixture case through the mobile grouping code.
4. **Mobile corrections.** Plain-text pages use the paper palette. An image whose embedded text is a node graph does not show that graph as its prompt.
5. **Rule.** `AGENTS.md` gains a short section: a change to a behaviour in the ledger updates its row in the same change, and a new behaviour a person could notice in more than one app gets a row.

## Acceptance

- The ledger covers every divergence the two audits reported, each with paths that exist.
- `scripts/test.sh parity` prints the three numbers and they match a count made by hand from the ledger's rules.
- The mobile suite runs all companion-grouping fixture cases and passes.
- A plain-text file opens on paper, and an image carrying a node graph shows no prompt taken from it.
- `scripts/test.sh mobile` passes and `git diff --check` is clean.
