# Design review — round 3

Date: 2026-10-22
Inputs: five refined native-prototype screenshots. Design review only, not production verification.

Screenshots inspected: grid-led-light.png, grid-led-dark.png, batch.png, remote-setup.png, grid-led-960.png. Purple indicator ignored.

**Verdict: ready for user feedback.** This is a design gate only. The screenshots cannot evidence the disabled Export hover hint, live remote status, keyboard flow, virtualization or persistence, so those stay as contract items, not verified behaviour.

The layout now matches the round 2 recommendation. Four columns at 1280 with a ~455×300pt preview, three full rows at 960 with the prompt still visible, Recents separated from This folder, batch counts on Archive and Trash, filename in the action bar, and a remote setup screen with no local toolbar.

**Remaining must-fix design problems**

1. **Active tile is still not readable at a glance.** In batch.png the active ring is only slightly darker and thicker than the two selected rings, and all three tiles carry the same checkmark. The dominant cue is the checkmark, which does not distinguish. Give the active tile one extra signal, such as a filled label strip or a different check glyph, so the action bar filename and the grid agree visually.

2. **Archive reads as a subfolder on disk.** In This folder, Archive sits in the same list as Architecture and Outdoors with only an icon difference. A user may expect to find an Archive folder in Finder, or may expect Architecture to behave like Archive. Put a divider or a separate subheading between real children and the app-managed Archive scope.

3. **Empty "This folder" header on the remote setup screen.** remote-setup.png shows the section header with nothing under it. Hide the header until a folder is open, or show a single muted line such as "No folder open".

**Tradeoffs to ask the user**

- **Preview height versus visible metadata at 1280.** At the default divider the File section heading is visible but its rows are clipped. Do they prefer the larger preview with a scroll, or a shorter preview that shows Details, Prompt, Generation and File without scrolling?
- **Favorite label in batch.** Archive and Trash show counts. Favorite does not, although it applies to all three. Consistent "Favorite 3", or keep it quiet because it is non-destructive and reversible?
- **Recursive All files by default.** With Architecture and Outdoors as visible children, All files flattens both. Is that the expected first view, or should All files mean the root's own files until a child is chosen? The toggle is deferred, so only the default is in question.
- **Appearance default.** Follow system, or always dark preview pane inside the system chrome? Both screenshots work. Dark gives the image more contrast, light reads better for metadata.
- **Footer shortcut hint.** Permanent or dismissable after first use.

## Follow-up disposition

Adopted an additional filled filename strip on the active tile, a separator before Archive, and hiding the empty This folder heading during first-use setup. Favorite now includes the batch count. These targeted follow-ups were visually checked after this review; no fourth design review is claimed.

Archive really does use an on-disk managed subfolder in the existing product. The separator clarifies its special Restore behavior rather than implying it is virtual. Follow-system appearance and recursive subtree scope remain the established defaults, not new open choices. The main user-feedback question is preview height versus immediately visible metadata.
