# UI review

Date: 2026-10-22
This is reviewer feedback, not verified implementation status. Decisions and verification are recorded in the task spec.

**Verdict:** the screenshot is an onboarding page where a picker should be. It contains 71 words and zero things to click except a handoff to another app. The proposed sheet is right. Fixed copy drops to 9 words, 15 with the empty state.

## Flow problems in the current screen

- **The only useful instruction is buried as step 2.** Step 1 happens in RelayBar, step 3 is system behaviour. Neither is something the user does in Frame.
- **Three verbs for one handoff.** The title says Open from, step 1 says Choose, the button says Continue. Pick one and keep it on the button.
- **Back to folder assumes a folder is open.** On first launch it is a dead control. In a sheet it becomes Cancel.
- **Read-only is stated twice** and pre-explains a dialog RelayBar owns. Let RelayBar ask when it asks.
- **The view replaces the workspace.** The left border shows it lives in the content area. The user loses place. A sheet over the window fixes that.
- **No RelayBar state.** If RelayBar is not running, the button fails silently. Disable Browse in RelayBar… when it is unavailable, with the reason in the tooltip only.
- **Dead end with no history.** Nothing on this page lets a returning user reopen last week's host and path.

## Exact copy

| Element | Before | After |
|---|---|---|
| Window title | Open from RelayBar | Open |
| Subtitle | Shared locations · read-only access | removed |
| Icon, headline | Your remote folders, in Frame. | removed |
| Paragraph | Connect through RelayBar. Your saved hosts… (18 words) | removed |
| Section header | none | Local |
| Local action | none | Choose Folder… |
| Section header | none | Remote |
| Step 1 | Choose a folder in RelayBar / Use your existing host and connection. | removed |
| Step 2 | Choose Open in Frame / Allow read-only access once, when RelayBar asks. | In RelayBar, choose Open in Frame. (empty state only) |
| Step 3 | Return here automatically / Preview images and metadata together. Originals stay on the host. | removed |
| CTA | Continue in RelayBar | Browse in RelayBar… |
| Secondary | Back to folder | Cancel |

Recent rows carry no labels. Local rows show the abbreviated path. Remote rows show host in bold, then the path. Return or double-click opens, so the sheet needs no Open button. Limit each section to five rows, newest first, delete with ⌘-Delete, no Clear button. Choose Folder… rather than Open Folder… avoids Open inside Open. Browse rather than Open in RelayBar avoids colliding with RelayBar's own Open in Frame item.

## Settings toggle

Use **Show remote folders**. It matches the macOS Show Path Bar convention and describes the visible effect. Enable remote browsing sounds like a permission or setup step and implies it never worked when off. The catalog stopping is implied by nothing being shown. Closing an open remote view is what hide means, so no explanatory sentence is needed. If Frame ever gets a second remote source, append from RelayBar. Otherwise do not.

## Stop and partial results without words

- **While scanning:** the count in the grid header reads `Scanning… 1,240` with a small Stop button beside it. Escape also stops.
- **After Stop or hitting the bound:** the count becomes `1,240+` and the Include subfolders checkbox drops to the native mixed state. Mixed is the system's own word for partially applied. Clicking it again resumes. The bound reason lives in the tooltip on the plus sign, nowhere else.
- **Errors:** a warning glyph on the affected row only. The message appears in the preview pane when that row is selected. No banner, no dialog.
- **Remote tree:** every unexpanded remote folder shows a disclosure triangle, since Frame cannot know children without listing. On expand the triangle becomes a spinner. On failure it becomes the warning glyph with the error in its tooltip.
- **Parent navigation:** ⌘↑ inserts the parent above the current root, keeps the current node expanded and selected, and scrolls to it.
- **Empty local folders:** show them in the tree with no count. In the grid, two words: No images.
