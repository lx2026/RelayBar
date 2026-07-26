# Task 020 — Refresh GitHub Pages Landing Page

Status: Complete

Created: 2026-07-26

Completed: 2026-07-26

## Outcome

RelayBar’s tracked GitHub Pages site presents version 1.2.0 with a dark,
technical visual system based on the supplied landing-page reference.

## Delivery Boundary

- Keep the site as static HTML, CSS, and image assets under `docs/`.
- Preserve the stable version 1.2.0 download and repository links.
- Do not add the reference archive’s generated runtime or external font
  dependencies.
- Do not publish or deploy the site as part of this task.

## Work

- Rebuild the landing-page layout and responsive styling.
- Present the shipped tunnel, Remote Files, grouping, and security behavior.
- Add a higher-resolution hero screenshot produced from the current app image.
- Document the static GitHub Pages boundary.

## Acceptance

- The page has no horizontal overflow at desktop and mobile widths.
- The primary download links target the official version 1.2.0 ZIP.
- The hero image is higher resolution than the previous 760 × 880 asset and
  preserves the visible RelayBar interface.
- All local page assets and anchor links resolve.
- No generated page runtime, private credential name, or deployment secret is
  tracked.
- HTML validation, browser checks, and `git diff --check` pass.

Completion evidence is recorded in
[Task 020 verification](../../verification/020-landing-page-refresh.md).
