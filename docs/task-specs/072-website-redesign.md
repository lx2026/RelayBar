# Task 072 — Website redesign

Status: Implemented — 2026-11-17, not published. [Verification](../verification/072-website-redesign.md). The owner's acceptance is open.

## Outcome

The project website shows RelayBar where it lives, in the menu bar, and says what both apps are in five short parts, in place of nine sections built from one repeated pattern.

## Delivery Boundary

`docs/index.html`, `docs/styles.css` and the site's images. The owner chose direction A, "In the menu bar", from three mocked directions. No change to the apps, the releases, `docs/appcast.xml`, the READMEs or the social image. Publishing is a separate step: the site goes live when this reaches `main`.

## Work

- Replace the page with five parts: a hero with the popover hanging from a drawn menu-bar strip, three facts, Remote Files, a dark band for Frame, and one Download list.
- Put everything about stable and beta in that list and the two sentences around it, in place of badges and notice boxes.
- Drop the grid-paper background, monospace labels, pill badges, and the drawn terminal and window bars around screenshots.
- Keep the apps' paper palette in light and dark, the system font, and a page with no script or third-party request.
- Remove screenshots that nothing references any more.

## Acceptance

- The page reads correctly at 1280, 760 and 390 pixels wide, in light and dark, with no horizontal scrolling.
- Every link resolves; the primary download is still stable 1.6.0, and each beta link names its beta.
- Text meets a 4.5:1 contrast ratio in both schemes, and every link and button is at least 44 pixels tall.
- The release document's website paragraph describes the new page.
