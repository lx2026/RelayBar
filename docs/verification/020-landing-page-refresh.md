# Task 020 Verification

Date: 2026-07-26

## Automated Checks

- `npx --yes html-validate docs/index.html` — passed.
- `git diff --check` — passed.
- Local asset checks — `styles.css`, icons, social image, tunnel screenshot,
  Quick Add screenshot, and Remote Files concept image all exist.
- Anchor checks — `#content`, `#top`, `#remote-files`, `#how-it-works`, and
  `#whats-new` all resolve.
- Stable download check — both download actions target
  `v1.2.0/RelayBar.zip`.
- Sensitive-name and generated-runtime scan — no notary profile name,
  `support.js`, generated template placeholder, or external font host appears
  in the changed site files.

## Asset Evidence

- Previous hero screenshot: 760 × 880 pixels.
- Generated hero screenshot: 1165 × 1350 pixels.
- The enhanced screenshot preserves the RelayBar menu, tunnel groups, visible
  profile names, Remote Files action, SSH notice, and Quit action.

## Browser Evidence

The site was served locally and checked in the in-app browser.

- Desktop at 1440 × 1000: page content rendered, all visible images loaded,
  document width matched the viewport, hash targets resolved, and no console
  errors or framework error overlay appeared.
- Mobile at 390 × 844: document width matched the viewport after tightening
  the decorative hero and CTA elements, and no console errors or framework
  error overlay appeared.
- The desktop hero, Remote Files, and Quick Add sections were visually
  inspected.
- The mobile hero, proof strip, Remote Files, workflow, release cards,
  principles, CTA, and footer were visually inspected.
- Lazy-loaded Remote Files and Quick Add images resolved to their expected
  1804 × 872 and 760 × 880 natural sizes when scrolled into view.

## Delivery Evidence

- The supplied generated page runtime and its support script were not copied
  into `docs/`.
- The site uses only static HTML, CSS, and local image assets.
- No commit, push, GitHub Pages deployment, or release publication was
  performed.
