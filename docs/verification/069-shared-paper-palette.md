# Task 069 — Shared paper palette

Date: 2026-11-17. Committed locally (`6a2a04d` for the shared package, `5909f1c` and `ff86044` for the apps, `3d140fa` for these records); not pushed or released. RelayBar 2.0.0 (25) and Frame 2.0.0 (19), built from that tree, are installed and are the first installed builds with the palette (see [Installed builds](#installed-builds)). Nothing has been checked by hand in the installed apps yet: every check below comes from unit tests, builds and captures drawn in off-screen test windows.

## What changed

- **One palette.** The new `HouseStyle` module in `Packages/AppComposition` holds `HousePalette`: Frame's paper, panel, stage, card, selected, ink, muted, faint, line, fill, amber, red, button and button-text values, and the status colours RelayBar's popover used (running green, retrying orange, warning and failure text). Each token also has a standard form built from macOS semantic colours. The values are written only there; [House style](../system-specs/shared/house-style.md) lists them.
- **Resolved when drawn.** A token's AppKit colour picks its value from the active form and the drawing appearance each time it is drawn. Its SwiftUI colour records the read with Observation, so a view that uses it is drawn again when the form changes.
- **Switching.** `HousePalette.apply(_:)` changes the form, marks every view of every open window for display, and posts `HousePalette.didChangeNotification`. SwiftUI views redraw in place with their state kept: through Observation from macOS 14, and on macOS 13, which RelayBar still supports, through a `@HouseTracking` property in every RelayBar and Plugins-window view that reads a token. Frame's Markdown and text pages on show take the new paper through an added style sheet without loading again, and every page takes the current paper when it finishes loading.
- **Paper Appearance.** One plugin, defined once in the shared package and listed in both catalogs: "Paper Appearance", "Uses the warm paper colours of RelayBar and Frame in this app. Turn it off for standard macOS colours.", `paintpalette`, on by default; on is paper, off is standard; each app keeps its own choice. It contributes no feature. Each app applies the saved choice when its composition is made, through the new `PreferenceStore.peek()`, which is before Frame's first window and before RelayBar opens any window, and applies every later choice as it is stored. The choice is the `paper` key in `preferences.json`.
- **Frame.** `FrameColors` and `FramePalette` now pass through to the palette. With the plugin on, every value and the Markdown page's style sheet are what they were (a `--frame-page` marker is the only addition to the style sheet).
- **RelayBar.** Popover and profile editor: paper behind, ink and muted text, line hairlines, fill for hover and pressed (pressed is the fill laid twice), the status tokens for the dot, arcs, triangle and orange and red text, faint for the stopped ring, card for rule cards. Settings: panel behind, card boxes with line edges and dividers, ink and muted text. Remote Files: panel sidebar, paper content and file list, stage behind an image, with the plugin on; with it off, the translucent sidebar and system backgrounds it had before. The Quick Add card and accent selections are unchanged.
- **Plugins window** (both apps): panel columns, paper map, card nodes, line dividers and edges, ink and muted text, status tokens for the phase marks. A plugin's summary may now take four lines, because Paper Appearance's is longer than three at the column's width.
- **Quiet tests.** RelayBar's and the shared package's window-making tests now use `QuietWindow` from `CompositionFixtures`, or `QuietSettingsWindow` for RelayBar's Settings window. Their frames are moved far off every screen, they are never key or main, ordering them in puts them behind everything, full screen is refused, and the test process cannot activate. The Settings window controller takes its window type so a test can supply the quiet one.

## Captures

All drawn in off-screen windows by the test processes: RelayBar's through `VisualSnapshotHarness/testCaptureTask069PaperAppearanceSnapshots`, Frame's Markdown page through `PaperAppearanceTests/testWritesPaperAppearanceDocumentSnapshots`. The 28 files are in the git-ignored `.build/task-069-design/`, named `069-<view>-paper-<on|off>-<light|dark>.png`, with Frame's Plugins window snapshots beside them. Eight are kept here:

- [Popover, plugin on, light](assets/069-paper-palette/popover-paper-on-light.png) and [plugin off, dark](assets/069-paper-palette/popover-paper-off-dark.png)
- [Profile editor, plugin on, dark](assets/069-paper-palette/editor-paper-on-dark.png)
- [Settings, plugin on, dark](assets/069-paper-palette/settings-paper-on-dark.png) and [plugin off, light](assets/069-paper-palette/settings-paper-off-light.png)
- [Remote Files with an image in its well, plugin on, light](assets/069-paper-palette/remote-preview-paper-on-light.png) (reduced to 1280 pixels wide)
- [Plugins window, plugin off, light](assets/069-paper-palette/plugins-paper-off-light.png)
- [Frame's Markdown page, plugin off, light](assets/069-paper-palette/frame-markdown-paper-off-light.png)

As in earlier captures, switches that are on and prominent buttons are drawn grey and the About row shows a folder icon, because the test process is not the active app.

Frame's whole window was not captured. The capture tool in `.build/task-068-design/tools/` does start the verification build with LSUIElement and the accessory activation policy, so it has no Dock icon, swallows every activation call, refuses full screen, answers the open panel without showing it, and moves titled windows to (−20000, −20000) as they are ordered in. But that last guarantee depends on AppKit and SwiftUI ordering every window through `-orderWindow:relativeTo:`, which its code cannot show, untitled windows are not moved at all, and the quiet mode has never been run. It could not be made certain from the code, so it was not used. Instead, Frame's own document renderer drew the Markdown page in an off-screen test window: with the plugin on its page colour reads `#f9f9f8` light and `#303133` dark as captured, the same pixels as the page area of `.build/task-068-design/01-files-markdown-*.png`, and a test holds the style sheet equal to Task 068's apart from the marker.

## Acceptance

| Criterion | Evidence |
| --- | --- |
| Captures of the popover, editor, Settings, Remote Files and Plugins window, plugin on and off, light and dark | 24 RelayBar captures in `.build/task-069-design/`; reviewed by eye. |
| Frame unchanged with the plugin on; one capture with it off | `PaperAppearanceTests` hold every `FrameColors` value and the page style sheet to Task 068's; the captured page colour matches Task 068's capture; Markdown captures with the plugin on and off. The full window was not captured (see above). |
| Text tokens keep 4.5:1 on their surfaces, both appearances and forms | `HousePaletteTests.testTextKeepsAtLeastFourAndAHalfToOneOnItsSurfaces` and `testInvertedTextKeepsItsContrast`; `PopoverPresentationTests` for the popover's text on its paper; Frame's existing contrast test. |
| Switching recolours open windows without restarting | `HousePaletteTests.testAnOpenWindowRedrawsInTheNewFormKeepingItsState` (an AppKit view draws again; a SwiftUI view and its button style redraw in the new colours and are not made again); `testAPageOnShowFollowsTheFormWithoutReloading` for Frame's page; both apps' plugin tests switch through the composition and see the notification. |
| No token literal outside the shared palette | A search of the apps' and package's sources finds the values only in `HousePalette.swift` and in the tests that pin them. The app-icon drawing script and old design prototypes keep their own artwork colours. |
| Tests show nothing on screen | Every window the three suites make is a quiet window; the one test that needs a key window is skipped unless `RELAYBAR_KEY_WINDOW_TESTS=1`. |
| Checks | See [Checks](#checks). |

## Checks

`./scripts/test.sh all`, after the review fixes: 9 script tests; 102 shared tests with 3 skipped; 452 RelayBar tests with 33 skipped; 220 Frame tests with 3 skipped; no failures. Frame builds with warnings as errors; the unsigned Release `xcodebuild` of `Apps/RelayBar/RelayBar.xcodeproj` succeeds with the new `HouseStyle` package product added; `git diff --check` is clean.

## Review

An independent review found six problems; all were fixed.

- **macOS 13 lost view state.** `houseStyled()` rebuilt the popover, Settings, Plugins and Remote Files content on a switch, losing a half-typed profile, the popover's screen, an open sheet, expanded hosts and a playing video. It is gone. Each view that reads a token declares `@HouseTracking`, an observed property that redraws that view's body in place. `HousePaletteTests.testWithoutObservationATrackedViewRedrawsInPlace` takes this path with Observation switched off and checks the colours change, including inside a geometry reader and a button style, and the view is not made again.
- **Standard hover fill too dark for status text.** The quaternary label fill put red text on a highlighted row at 4.39:1 here, and about 3.7:1 on macOS 13 to 15. The standard fill is now the label colour at 7%, and standard warning and failure are derived from macOS's orange and red to stay readable. `testTextKeepsAtLeastFourAndAHalfToOneOnFills` pairs ink and muted with the fill over paper, panel and card, laid twice and at 1.6 times over paper, and warning and failure with the fill over paper.
- **A page made before a switch kept the old paper.** Every page now takes the current paper when it finishes loading; `testAPageMadeBeforeASwitchTakesTheNewPaperWhenItLoads` fails without that line.
- **Show on Map did nothing for Paper Appearance.** It is offered only for plugins with features.
- **Summary wording.** Now "Uses the warm paper colours of RelayBar and Frame in this app. Turn it off for standard macOS colours."
- **Remote Files did not look as before with the plugin off.** The standard form brings back the translucent sidebar, the list's own background and the text background behind previews.

The checks it asked for:

- Observation is weak-linked: in the unsigned Release build `otool -l` shows `LC_LOAD_WEAK_DYLIB /usr/lib/swift/libswiftObservation.dylib` with `minos 13.0`.
- Frame's grid background and its missing-thumbnail symbol kept their old colour until light or dark changed (a layer colour and a cached tinted symbol, confirmed in a quiet experiment). The grid is now given the active form's paper again on each switch, and the symbol is drawn from its name each time.
- Colours read inside closures: on macOS 14 and later Observation picks them up, including inside a geometry reader. On macOS 13 a closure re-runs only if it captures something, so the Settings "Size limit" heading now captures its colour; the popover's scroll container content captures its view.
- Before Frame's preference document loads, `isPluginEnabled` read the default. Both apps now read the saved choice through `peek()`, so a Plugins window shown first agrees with the colours.
- Frame's page colour was resolved on the parser's background actor. It is now read on the main actor and handed to the parser.

## Decisions the brief left open

- Paper Appearance contributes no feature and is applied by each app's composition from its preference document, so it never appears on the Plugins map and switching it reloads nothing.
- Standard mapping: paper is the window background; panel and stage are the under-page background; card is the control background in light and a lifted under-page colour in dark; muted sits halfway between the secondary label and label colours; fill is the label colour at 7%; button is the label colour with window-background text; warning and failure are macOS's orange and red moved towards black in light (and the red towards white in dark) so they stay readable on a highlighted row.
- The dark failure red moved from `#ff6b62` to `#ff736b` so error text in a dark Settings box keeps 4.5:1. Frame's own red, used only for icons, is unchanged.
- Settings' error note uses the failure colour; the Revoke button keeps the system red of a destructive control.
- RelayBar's Markdown, JSON, text and HTML previews keep their own page colours. Frame's Markdown page keeps its green links and text colours in both forms; only its background follows the paper.
- RelayBar's Remote Files window maps surfaces only; its text keeps the system label colours.
- The pressed fill is the hover fill laid twice rather than a separate token.
- With the plugin off, RelayBar differs from its look before this task in a few places the brief's standard mapping decides: the Settings window is on the under-page grey with white boxes (lighter boxes in dark), the Plugins window's side columns are on the under-page grey, the running dot and retrying arc use macOS's green and orange, and status text uses the derived orange and red. Remote Files was brought back to its earlier look on review.

## Still to check by hand

- Switch Paper Appearance in each app's Plugins window with the popover, Settings, Remote Files and Frame's window open: every one changes at once, and Frame's open Markdown page keeps its scroll position.
- Quit and relaunch with the plugin off: no window shows the paper colours first.
- RelayBar on macOS 13, if a Mac with it is available: it starts, and a switch redraws open windows while a half-typed profile, an open sheet and a playing video stay as they were.
- Switches, prominent buttons and the app icon in Settings drawn as active, which the captures cannot show.
- `RELAYBAR_KEY_WINDOW_TESTS=1 swift test --package-path Apps/RelayBar --filter testMarkdownPreviewKeepsTheWindowKeysWhetherOrNotItHasTheFocus` at a Mac nobody is using.

## Installed builds

RelayBar 2.0.0 (25) and Frame 2.0.0 (19) were notarized and installed locally on 2026-11-17 from commit `3d140fa` with only their build numbers raised. Earlier installed builds (RelayBar 23 and 24, Frame 17) do not have the palette or the Paper Appearance plugin. The installation evidence is under [Task 067](067-switchboard-popover-settings-window-icon.md#local-installation-build-25) and [Task 068](068-frame-reader-layout.md#local-installation-build-19). RelayBar's Release executable weak-links `libswiftObservation` with a minimum OS of 13.0; it has not been launched on macOS 13.

## After the first CI run

The pull request's first CI run, on macOS 15, failed four contrast assertions in `HousePaletteTests`, all in the standard form. On macOS 13 to 15 the under-page background is a mid grey in light appearance and the window is lighter in dark than on the Mac the palette was developed on, so the standard panel was too dark for a sidebar and the fixed darkening of the status colours was not enough (orange and red text on the panel measured 2.4:1). The paper form was not affected.

- The standard panel is now the under-page colour only where it is within 1.25:1 of the window colour, and the window colour otherwise; the standard dark card is lifted from that panel.
- Standard warning and failure text start from the same amounts as before and move further, in 5% steps, until they keep 4.6:1 on the standard paper, panel and card, plain and under the fill.
- `testStandardStatusTextStaysReadableOnTheWindowsOfOlderMacOS` checks this against fixed greys like those of macOS 15, so it is covered on any Mac; the panel rule is asserted in the values test.

On current macOS nothing changes: the under-page colour is still used and the status colours already passed. Builds 25 and 19 were made before this fix.
