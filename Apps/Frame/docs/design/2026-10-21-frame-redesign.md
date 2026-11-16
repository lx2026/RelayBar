# Frame: appearance, video, and folder selection

Design status: Accepted — user approved implementation; folder dropdown and temporary-grid decisions superseded below\
Date: 2026-10-21\
Scope: original reviewed design; delivered in 0.2.0 with the Contact Sheet amendment

## Implementation amendment — 2026-10-21

During implementation the user requested a powerful selection screen with conventional multi-selection and batch deletion, and rejected long dropdown navigation. [Contact Sheet selection and batch Trash](../task-specs/2026-10-21-contact-sheet-selection.md) records the revised interaction contract, two further design reviews, and an authorized code audit. Contact Sheet is now the default browsing surface, with a collapsible folder outline and attached preview/metadata. Inspect remains sidebar-free. The historical prototype below is not a mock of these later changes. [Native screenshots and delivery evidence](../system-specs/verification-2026-10-21.md) describe the installed result.

## Direction

One folder chooser, one media selection, one attached metadata panel.

The toolbar's folder name opens **Choose Folder…**, recent folders, and Refresh. A small subfolder selector narrows the current root when there are meaningful alternatives. There is no permanent sidebar. All/Favorites appears once and applies to the selected subtree.

The inspection workspace retains the large image or video and the attached metadata column. The mixed filmstrip uses a play badge and duration to identify videos. Contact Sheet remains a temporary way to jump to another file. Focus hides the filmstrip while keeping metadata visible.

[Interactive mock source](assets/2026-10-21-frame-redesign/frame-redesign.html)

## Appearance

Follow the macOS appearance, including changes while the app is open. Use paired surface/text colors across toolbar, stage, inspector, filmstrip, menus, prompts, buttons, and selection. Keep the interface neutral; amber remains the favorite accent. The mock's Appearance control is a design-preview control, not a proposed new product toolbar item.

The current defect is visible in `FramePalette`: fixed light surface colors coexist with system-adaptive foreground text. Fix the paired colors rather than forcing the entire application to light mode.

## Video

Add local MP4, MOV, and M4V containers through AVFoundation/AVKit. Actual playback depends on macOS support for the file's codec. No transcoding or codec downloads.

- Start paused; stop playback when selection, root, or folder/filter scope changes.
- Keep playback position when entering or leaving Focus.
- Show duration, dimensions, frame rate, codec, size, creation date, and audio presence when available.
- Keep available file metadata visible when decoding fails. Offer Reveal in Finder with a concise failure message.
- Use the same favorite, Trash/Undo, and byte-exact export actions as images.

## Folder flow

1. First launch presents one Choose Folder action, a folder drop target, and recent folders.
2. Opening a folder scans recursively and selects the first supported item. Nothing is imported.
3. Clicking the toolbar folder name offers root switching and reopening a recent folder directly.
4. The subfolder selector is only shown if its choices produce different result sets; full relative paths distinguish duplicate names. All files includes descendants.
5. Switching roots resets folder scope/filter and stops playback, while each root's favorites remain saved.
6. An unavailable folder keeps its name visible, displays Unavailable in the chooser and recent list, and offers Locate Folder. Reauthorizing an existing root must retain its catalog identity and favorites.

Recent folders are a view of existing bookmark records, limited to eight visible entries. Removing a recent shortcut must not delete originals or favorite records. Manual refresh remains; filesystem watching is outside this revision.

## Keyboard contract

| Intent | Key | Boundary |
| --- | --- | --- |
| Choose folder | ⌘O | Native folder panel |
| Previous / next file | ← / → | Viewer owns navigation; focused player controls retain their standard behavior |
| Favorite | F | Selected media, outside editable fields/menus |
| Contact Sheet | G | Existing temporary grid |
| Play / pause | Space | Video only; no action for an image |
| Focus | Return | Viewer focus; buttons retain Return activation |
| Leave layer | Escape | Close the topmost popover/sheet, then Contact Sheet, then Focus; one layer per press |
| Undo Trash | ⌘Z | Native undo action, retained beyond the brief toast |
| Refresh | ⌘R | Current root |
| Export | ⇧⌘E | Byte-exact copy with destination replacement |
| Move to Trash | ⌘⌫ | Selected original; never permanent deletion |

Focus's old Space shortcut changes deliberately to prevent a mixed photo/video collection from assigning conflicting meanings to Space. Shortcut hints belong in native menus and tooltips.

## Design review record

The first attempt failed; a retry of round 1 completed successfully. Reviews were read-only and did not modify the project.

### Round 1: concept

Feedback: consolidate redundant navigation, define failure states, make the keyboard model explicit, cap and deduplicate recent roots, and load video metadata asynchronously.

Revision: built a working mock with menu and rail alternatives, mixed media, theme previews, and explicit empty/missing/unsupported states. Space is reserved for playback. Existing root-relative favorite identity is retained.

Not adopted: Space as Focus in Inspect and Play inside Focus, because that still changes the same key's meaning. File-drop opening and a permanently dark stage are not requirements of this revision.

### Round 2: working mock

Recommendation: **Folder menu**, because it preserves more image space and avoids a sidebar toggle plus a second subfolder selector.

Revision: removed the rail, hid the duplicate start toolbar, corrected Escape precedence, isolated keys from popovers/sheets, added shortcut hints and unavailable-root identity, removed redundant type labels, and added a session undo stack behind the seven-second toast.

Not adopted: dropping light mode (the user asked to fix dark mode, not force dark mode), adding filesystem watching, or deleting the existing Contact Sheet. Responsive stacking remains only for reviewing the mock inside a narrow conversation; the native minimum stays 960 × 640.

### Round 3: final audit

The review identified missing explicit system-theme fallback, keyboard actions bypassing unavailable states, and Space/Return intercepting the metadata disclosure. It recommended user review after these fixes and tests.

Revision: declared supported light/dark schemes and cleared the forced scheme in System mode; centralized media-action/playback availability; prevented playback in Contact Sheet and unsupported states; respected disclosure keyboard ownership; and added regression checks for these paths. Transient simulated deletion/undo state no longer persists across preview reloads.

The review also questioned tooltip rendering. The preview runtime explicitly implements `data-tooltip`; adding a competing tooltip system was unnecessary. Native implementation must use SwiftUI help and menu shortcuts. The completed third review was followed by the targeted fixes and passing checks; no fourth review is claimed.

## Delivered implementation

- [Adaptive appearance](../task-specs/2026-10-21-adaptive-appearance.md)
- [Video viewing](../task-specs/2026-10-21-video-viewing.md)
- [Simplified folder selection](../task-specs/2026-10-21-folder-selection.md)

The user approved these specs, then added the Contact Sheet amendment above. Delivery evidence is recorded in the task completion records and living system spec.

## Prototype verification and limits

`node Scripts/verify-design-mock.mjs` checks folder/root switching, scoped favorites, video control state, stop-on-navigation, Trash/Undo, layered Escape, keyboard isolation, and light/dark choice. A static contrast check found a minimum 5.08:1 ratio among the tested primary/secondary text and button pairs.

Playback, file actions, clipboard actions, and the folder panel in this historical prototype are simulated. Sample artworks and metadata are illustrative. It does not decode video or access user media. Browser rendering was not verified: the browser tool rejected local-file navigation. These prototype limits do not describe the subsequently built and installed native app; see the linked delivery evidence above.
