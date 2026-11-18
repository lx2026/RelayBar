# Task 072 — Website redesign

Date: 2026-11-17. Built on a feature branch; not committed to `main` and not published. The owner has not yet reviewed the built page in a browser.

## What changed

The owner said the live page did not look good. Three directions were mocked beside a capture of the live page, and the owner chose A, "In the menu bar". `docs/index.html` and `docs/styles.css` were rewritten to it: 303 lines of markup in place of 621, and 625 lines of styles in place of 1,380. Four screenshots that nothing references were removed.

| Before | After |
|---|---|
| Nine sections, most built as a small label, a large headline and three boxes | Five parts: hero, three facts, Remote Files, Frame, Download |
| Popover in a drawn frame labelled like code, beside badges and a terminal line | Popover hanging from a drawn strip of the menu bar |
| Stable and beta explained in badges, a banner and two notice boxes | One Download list of three rows, with a sentence above and below |
| Grid-paper background, monospace labels, pill badges | Plain paper ground; monospace only for commands |

## Checks

All captures were made by a headless browser with no window.

- **Widths.** Read at 1280 pixels wide, and at 760 and 390 pixels in fixed-width frames, because the headless browser will not make a window narrower than about 500 pixels. Below 900 pixels the hero, Remote Files and the facts stack into one column and each Download row becomes two lines. Nothing scrolls sideways.
- **Light and dark.** The Mac was in dark mode, so the dark capture is the page as written. The light capture was made from a copy with the dark values and the dark popover source removed, which is what a light-mode visitor's browser applies. In dark mode the hero shows the dark popover; the Remote Files and Frame pictures stay light.
- **Links.** All nine external addresses answered 200, every local file the page names exists, and every in-page link has its target. The primary download is `v1.6.0`; each beta link names its beta.
- **Contrast.** Computed for every text and ground pair in both schemes: the lowest is 4.99:1, link blue on paper.
- **Targets.** Links in the header, footer and Download list and both buttons are at least 44 pixels tall.
- **No script.** The page loads its stylesheet and images only.

## Still to check

- The page in real browsers, Safari included, and on a phone.
- The social preview image still carries the old headline, "SSH tunnels, one click away."
- The screenshots are captures of a verification build with sample data; switches in them draw grey.
