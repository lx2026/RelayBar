# Shared paper palette

Status: Implemented, awaiting the owner's hand check — 2026-11-17. The owner likes Frame's colours and asked for them to become the default for the apps in this repository, possibly as a plugin. Evidence: [verification record](../verification/069-shared-paper-palette.md).

## Outcome

RelayBar and Frame draw from one palette, the warm paper tones Frame already uses, defined once in the shared package. A plugin, on by default in both apps, switches an app between that palette and standard macOS colours.

## Delivery Boundary

Colours only, in the shared package, RelayBar and Frame. Layout, wording, behaviour, the system accent colour, stored data and the bridge protocol do not change. Automated tests must not show windows or take focus. No version change, install, push or release.

## Work

- Put Frame's colour tokens (paper, panel, stage, card, ink, muted, faint, line, fill, amber and the status colours RelayBar uses) in the shared package with their light and dark values, as the only place those values are written.
- Give the palette a second, standard form that maps each token to the matching macOS semantic colour.
- Add one plugin, "Paper Appearance", to both apps' catalogs, on by default. Switching it changes the app's open windows at once and is remembered like any other plugin.
- Frame reads its colours from the shared palette, with no visible change while the plugin is on.
- RelayBar's popover, profile editor, Settings window, Remote Files window and its use of the Plugins window read theirs from it too.
- Make RelayBar's and the shared package's window-making tests run off screen, as Frame's already do.

## Acceptance

- Captures of RelayBar's popover, profile editor, Settings window, Remote Files window and the Plugins window exist with the plugin on and off, in light and dark; Frame's captures with the plugin on are unchanged, and one with it off exists.
- Every text token keeps at least 4.5:1 contrast on each background it is drawn on, in both appearances and both forms, checked by tests.
- Switching the plugin recolours open windows without restarting.
- No colour literal for these tokens remains outside the shared palette.
- Running the test suites shows nothing on screen. `scripts/test.sh`, both app builds and `git diff --check` pass; the system specs describe the palette and the plugin; a verification record lists what changed and what needs a hand check.
