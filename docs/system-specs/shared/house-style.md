# House style

RelayBar and Frame draw from one palette, `HousePalette` in the `HouseStyle` module of `Packages/AppComposition` ([Task 069](../../task-specs/069-shared-paper-palette.md)). Its token values are written nowhere else. The system accent colour is not a token; both apps keep using it for selections, plugin marks, RelayBar's group actions and its Quick Add card.

## Tokens and forms

Each token has two forms. **Paper** is Frame's warm palette, light and dark. **Standard** uses the matching macOS semantic colour. UIKit uses the measured light and dark sRGB values of the macOS 27 standard appearance as inputs to the same mixing and contrast calculations.

| Token | Role | Paper (light / dark) | Standard |
| --- | --- | --- | --- |
| paper | main surface: Frame's reader and grid, the popover, Remote Files content, the Plugins map | `#f8f8f6` / `#242526` | window background |
| panel | sidebars, side columns, the Settings window | `#f0f0ed` / `#292a2b` | under-page background where it is close to the window colour (contrast 1.25:1 or less), as on current macOS; otherwise the window background, as in light appearance on macOS 13 to 15, where the under-page colour is a mid grey |
| stage | the well behind a picture or preview | `#e4e5e1` / `#17191a` | under-page background |
| card | Settings boxes, rule cards, tiles, map nodes | `#ffffff` / `#343637` | control background in light; in dark the standard panel colour lifted 6% towards the label colour, so a box stays lighter than its panel |
| selected | an unfocused selection | `#d4d7cf` / `#3d403b` | unemphasized selected content background |
| ink | primary text | `#252823` / `#eeefeb` | label |
| muted | secondary text | `#585d54` / `#b5b9b0` | halfway between the secondary label and label colours, because the secondary label colour alone falls below 4.5:1 on a light window |
| faint | placeholder glyphs, the stopped-tunnel ring | `#8b8f86` / `#80847c` | tertiary label |
| line | hairlines | ink at 12% / white at 10% | separator |
| fill | fields, blocks, hover; pressed is the fill laid twice | ink at 7% / white at 8% | label colour at 7%, about as faint as RelayBar's earlier hover |
| amber | favourites | `#805000` / `#f1bd62` | system orange |
| red | destructive actions | `#b8241a` / `#ff6b62` | system red |
| button, buttonText | a prominent button and its text | `#30352d`, `#ffffff` / `#e2e6dc`, `#252823` | label, window background |
| running | a running tunnel or feature | `#28a745` / `#32d158` | system green |
| retrying | the retrying arc, a stuck feature | `#f08c00` / `#ff9f0a` | system orange |
| warning | orange status text | `#a34e00` / `#ffb340` | system orange, 45% towards black in light; then further, in 5% steps, until it keeps 4.6:1 on the standard paper, panel and card, plain and under the fill |
| failure | red status text, the failure triangle | `#c92a1e` / `#ff736b` | system red, 30% towards black in light and 25% towards white in dark; then further, in 5% steps, until it keeps 4.6:1 on the standard paper, panel and card, plain and under the fill |

macOS's own orange and red are too light for small text, so the standard form moves them as shown; that also keeps them readable on a highlighted row over the grey window of macOS 13 to 15. The paper dark failure red is a shade lighter than the popover's earlier `#ff6b62`, which fell just short of 4.5:1 on a dark card.

Text tokens hold at least 4.5:1 on every surface they are drawn on, in both forms and appearances: ink and muted on paper, panel, card, stage and selected, and on the fill over paper, panel and card, laid twice over paper (a pressed popover button) and at 1.6 times over paper (Frame's hovered details); warning and failure on paper, panel and card, and on the fill over paper (a highlighted popover row); amber, in the paper form, on paper, panel, stage and selected; button text on a button and paper on ink.

## Drawing and switching

On iOS, `uiColor` resolves against the drawing trait collection. Form changes invalidate SwiftUI colour reads, mark views in connected window scenes for display and post `HousePalette.didChangeNotification` on the main thread. Applying the current form again does nothing.

A token's `nsColor` is a dynamic colour that picks its value from the active form and the drawing appearance whenever it is drawn. `HouseColor` (or `token.color`) gives the SwiftUI colour for the active form, and reading it in a view's body records the read with Observation. Every RelayBar and Plugins-window view that reads a token also declares `@HouseTracking private var house`, which reports the form and, on macOS 13, where SwiftUI cannot see the read, draws the body again in place when the form changes. `HouseDivider` is a hairline in the line colour with a `Divider`'s size and direction.

`HousePalette.apply(_:)` switches the form, then redraws every open window at once, with every view keeping its state: SwiftUI views that read a token are drawn again in place (through Observation from macOS 14, through `HouseTracking` on macOS 13); every AppKit view in every window is marked for display, so a view that draws with a token in `draw(_:)` picks up the new value; and `HousePalette.didChangeNotification` reaches anything that keeps its own copy: Frame's grid background, which AppKit holds as a layer colour, and its open page. Frame draws its missing-thumbnail symbol from its name each time, because a stored tinted symbol keeps the colour it was made with. Observation is weak-linked, so RelayBar still starts on macOS 13.

Frame's Markdown and text pages take the reader column's paper as their page colour when they are made (read on the main actor and handed to the parser), a page already on show takes the new paper through a small style sheet added when the form changes, without loading again, and every page that finishes loading is given the paper of the form in use then, so a page made before a switch and shown after it still matches. HTML pages keep their own colours on their white card. RelayBar's Markdown, JSON, text and HTML previews keep their own page colours.

## Paper Appearance

`PaperAppearance.plugin` (id `paper`, title "Paper Appearance", summary "Uses the warm paper colours of RelayBar and Frame in this app. Turn it off for standard macOS colours.", symbol `paintpalette`) is in both apps' catalogs and on by default: on is the paper form, off the standard form. Each app has its own choice. It contributes no feature, because it changes how the shell draws rather than what runs, so the Plugins window offers no Show on Map for it. Each app's composition applies the saved choice when it is made, reading the preference document with `PreferenceStore.peek()` before anything has loaded, so the first window already has the right colours, and applies every later choice as it is stored. Until the document loads, `isPluginEnabled` reads the saved choice the same way, so a Plugins window shown first agrees with the colours. The choice is the `paper` key of the `plugins` object in `preferences.json`, stored only when it differs from the default.

## Where each app uses it

- RelayBar's popover and profile editor: paper behind, ink and muted text, line hairlines, fill for hover and pressed, the status tokens for the glyphs and the orange and red text, card for the rule cards, line for their edges. The Quick Add card and selections stay accent.
- RelayBar's Settings window: panel behind, card boxes with line edges and dividers, ink and muted text, failure for an error note.
- RelayBar's Remote Files window: in the paper form, panel sidebar, paper content and file list, stage behind an image preview; in the standard form it keeps its earlier look, a translucent sidebar, the list's own background and the text background behind previews.
- The Plugins window in both apps: panel for the plugin and inspector columns, paper for the map, card for map nodes, line for dividers and node edges, ink and muted text, and the status tokens for the phase marks.
- Frame: every surface, text and mark, through `FrameColors` (AppKit) and `FramePalette` (SwiftUI), which pass through to the palette.

Alerts, menus and system controls keep their system colours.
