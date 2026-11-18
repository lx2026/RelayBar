# Design review — round 2

Date: 2026-10-22
Inputs: six native-prototype screenshots. No user media or remote host data.

Screenshots inspected: image-led-r1.png, image-led-light-r1.png, grid-led-light-r1.png, grid-batch-r1.png, remote-setup-r1.png, image-led-960-r1.png. All six, at 1280×832 and 960×672pt equivalents. I ignored the purple capture indicator.

## Recommendation: Grid-led as the single default

Grid-led serves all three user priorities. Image-led serves only the first one, and only on paper.

Measured in the prototype, Image-led does not actually deliver a big image. The preview pane is wide but only ~295pt tall, so the 3:2 image fits by height and lands at roughly 340×225pt with empty dark margins on both sides. The metadata column beside it is ~220pt and already scrolls. The cost of that pane is the grid: one and a half rows at 1280, and a single row of six tiles at 960. That is a filmstrip, not a contact sheet, and it makes culling slower than the installed app.

Grid-led shows all nine assets in three full rows, gives the prompt a comfortable line length, and keeps Favorites, size and count in one header. Its weakness is the preview, which is only ~265×175pt because the inspector is 375pt wide. That is fixable by widening the inspector. Image-led's weakness is structural: a landscape preview and a multi-row grid cannot share 800pt of height.

Do not ship both layouts. A toggle adds scope and splits the culling muscle memory.

## Five highest-impact changes

1. **Widen the inspector and let the preview fill it.** Inspector 440pt at 1280 and 400pt at 960, with the preview region taking the top ~45% of inspector height and the image fitting to width. That yields roughly 440×293pt at 1280, larger than either prototype preview. The grid then gets ~700pt at 1280, which is four tiles at ~165pt or five at ~130pt. Keep the divider draggable and remember it.

2. **Make the active item visibly different from the other selected tiles.** In grid-batch-r1.png all three selected tiles have identical borders and checkmarks. The only cue is "Active in selection" in the inspector corner, which nobody reads while culling. Give the active tile a thicker accent ring, and change the action bar text to "Sea pavilion.png · 3 selected". Label Archive with the count the same way Trash is labelled, since it confirms. Give disabled Export a hover hint: "Select one item to export". Define Favorite on a mixed selection as "add to all", and show the star filled only when every selected item is a favorite.

3. **Fix large-folder navigation before the grid meets a real folder.** "Includes subfolders" is a footer note, yet it recursively flattens everything into one undifferentiated wall. Thousands of AI outputs from many run folders will be unculllable. The round 1 direction promised subfolder children in the rail. The prototype shows none. Add the children under the root in the rail, make "includes subfolders" an explicit toggle in the grid header, and when it is on, insert subfolder group headers in the grid. Keyboard must carry the workflow: arrows move the active item, Return enlarges, Command-Delete trashes, with the shortcut hint in the footer reflecting those.

4. **Strip the preview chrome.** The non-functional "Preview" label, the "Fit · 2400 × 1600 · Enlarge" row and the image letterboxing together waste ~60pt of height and add three things to read. Dimensions already live under File. Keep one control, "Enlarge", as a hover overlay or a button in the inspector header, and give the image the full pane.

5. **Rail labelling and remote state.** The "Remote folder…" item with a plus sign reads as host setup inside Frame, which the product boundary forbids. Rename it to "Open from RelayBar…". The Render box row shows no state. Add a one-word trailing status: Connected, Needs approval, Offline. The rail also has no Recents section, although the round 1 direction and "app reopens last location" depend on one. Add it above the current root. The duplicate root/All files selection is already queued, so I have not counted it.

## 960×640 layout

Grid-led adapts cleanly, Image-led does not.

| Region | Width | Result |
|---|---|---|
| Rail | collapsed | Toolbar breadcrumb remains the location indicator. |
| Grid | ~560pt | Four tiles at ~130pt, three rows visible, about twelve tiles. |
| Inspector | ~400pt | Preview ~400×267pt, metadata below with filename pinned. |

Image-led at 960 shows six tiles in one row and a 318×210pt preview. Grid-led at 960 with the change above shows twice the tiles and a larger preview. That comparison alone settles the default.

## Real issues versus optional taste

The five items above are real issues. Everything below is taste or polish and should not block round 3.

- **Light versus dark.** The light chrome reads better for metadata. A dark preview pane inside light chrome is a reasonable hybrid and is what the light screenshots already do.
- **Paired JSON marker.** The curly-brace glyph on tiles is quiet but cryptic. A tooltip "Paired JSON" is enough. The "JSON" pill in the inspector header is fine.
- **Footer hint permanence.** The "click to add, click for a range" hint can stay, but it should not be the only keyboard documentation.
- **"On this Mac" in the toolbar.** It duplicates the rail section header. Keep whichever survives rail collapse, which is the toolbar one.
- **"Originals stay in their folders" at the rail bottom.** Good reassurance. Move it to the Open folder flow if the rail gets crowded by Recents and children.
- **Remote first-use panel.** The inline version is now clear: one sentence, two steps, one button, one return promise. Beyond the queued removal of the local action bar and breadcrumbs, no further change is needed.

## Author assessment

The review's pixel estimates are approximate, not layout measurements. The native prototype uses a 480 pt inspector; its preview was height-constrained. We adopted the structural recommendation (grid-led, less preview chrome), not the unverified measurements. Light mode has a light neutral stage, not the dark hybrid described in the optional comments.
