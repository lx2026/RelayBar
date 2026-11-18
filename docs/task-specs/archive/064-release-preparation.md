# Paired-app release preparation

Status: Complete — 2026-11-14. Local preparation only; [verification](../../verification/064-release-preparation.md). Application acceptance and publication remain separate.

## Outcome

Both apps have an explicit notarization path, the README and website accurately distinguish stable downloads from the source under test, and the uncommitted work has a reviewable commit breakdown.

## Delivery Boundary

Local preparation only. Preserve installed test apps, release versions and public download/feed URLs. No commit, push, Apple submission or publication. Acceptance of Tasks 058–063 remains separate.

## Work

- Route packaging and notarization by app; make Frame Release builds universal and verify accepted submissions and final archives.
- Update both READMEs and the static website for Frame, document rendering, plugin defaults and compatible paired updates.
- Inspect the complete prospective diff, including untracked files and renames, and prepare commit groups with remaining acceptance work.

## Acceptance

- Local tests cover both app routes, rejected/failed notarization and approval/argument guards without external service calls; Frame's signed Release bundle has both architectures and its renderer resources.
- README/site links and desktop/mobile presentation pass local checks; unreleased features are labelled and stable download URLs are unchanged.
- A commit inventory covers every changed file without staging the real index; generated artifacts and private configuration are excluded.
- Relevant system specs and verification evidence are updated, and `git diff --check` passes.
