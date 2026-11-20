# Task 081: iPad layout and remaining readers

Status: Complete
Design: [RelayBar for iPhone and iPad](../../designs/relaybar-ios.md)
Verification: [record](../../verification/077-083-relaybar-mobile.md)
Depends on: Task 080

## Outcome

The app uses an iPad's width, and reads every file kind the Mac apps read, with ways to take a file out of the app.

## Delivery Boundary

Included: `Apps/RelayBarMobile` and any read-only additions it needs in `Packages/RelayTransport`.

Excluded: the Plugins screen, per-host overrides and the plugins that write or widen access (Task 082); release work (Task 083).

## Work

1. iPad: a sidebar with the host switcher, the Open Location field, services and a file tree; the reader beside it with an outline rail; and two pages side by side with a divider. A document matches Frame's rendering at the same width.
2. Video: playback by byte ranges over SFTP through a resource loader, with seeks ahead of read-ahead, and download-then-play when streaming cannot keep up.
3. HTML files: rendered with scripts in a throwaway store that holds no token and uses no proxy. Internet resources load only after the user allows them for that host. The HTML Scripts plugin turns scripts off.
4. Notebook Preview and Table Preview as plugins that register preview formats: `.ipynb` read-only, and CSV and TSV as tables, each within a size limit.
5. Share and save to Files. A long download continues as a system-tracked task after the app leaves the screen.
6. Companion-file grouping, favourites and prompt search behave as in Frame. Data Saver stops thumbnails and read-ahead on expensive or constrained paths.
7. Dark appearance across every screen.

## Acceptance

- Logic tests on macOS: the range reader serves ordered and out-of-order ranges and a cancelled seek; the notebook and table parsers handle the fixtures and reject oversized input; the HTML permission is stored per host and defaults to off.
- A windowless web-view test shows a previewed HTML file unable to reach the localhost gate or the proxy.
- The app builds for the iOS Simulator SDK for iPhone and iPad with warnings as errors.
- The device checklist gains the iPad, video and AirPlay checks, marked not yet run.
- `docs/system-specs/modules/mobile-app.md` describes the result.
