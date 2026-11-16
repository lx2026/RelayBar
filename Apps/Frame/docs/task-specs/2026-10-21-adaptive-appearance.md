# 2026-10-21: Adaptive appearance

Task status: Completed — 2026-10-21; native matrix limits recorded below\
Design status: Accepted — user approved implementation; see the Contact Sheet amendment for later selection changes

## Outcome

Frame remains readable in macOS Light, Dark, and automatic appearance, including switches while the window is open.

The existing palette combines fixed light backgrounds with system-adaptive text. Replace surface/foreground pairs together across the toolbar, media stage, metadata panel, filmstrip, menus, selections, prompts, notices, and buttons. Retain the neutral palette and amber favorite accent.

## Design

[Reviewed design and three-round consultation](../design/2026-10-21-frame-redesign.md) · [Interactive mock](../design/assets/2026-10-21-frame-redesign/frame-redesign.html)

- Follow macOS appearance; no extra appearance control in the product toolbar.
- Keep the media and metadata adjacent in both appearances.
- Explicitly pair filled-button backgrounds and labels; a tint change alone is insufficient.
- Make secondary text, disabled controls, selection outlines, and focus rings distinguishable against their actual surfaces.
- Treat the mock's theme controls as preview controls only.

## Implementation boundary

Primary files: `FrameRootView.swift` (`FramePalette`), `MainWorkspace.swift`, and `MetadataPanel.swift`. Use semantic or appearance-aware native colors, including state surfaces currently expressed as fixed black/white opacity.

No media transformation, theme store, or new preference schema is required.

## Acceptance and verification

- [x] Native Inspect and Contact Sheet are readable in both appearances; Focus and menus use the same paired surfaces. Complete error/notice-state visual matrix remains a manual follow-up.
- [x] Live native appearance changes update the open window without relaunch, tested with a debug-only app appearance override.
- [x] Automated primary/secondary text and filled-button pairs meet 4.5:1; selected-cell outlines use the high-contrast primary foreground. Native control/focus visibility was inspected.
- [x] Favorite, Export, and disabled actions remain identifiable in both native appearances.
- [x] Image geometry and colors are unaffected by appearance changes.
- [x] Native same-image and same-video screenshots recorded in Light/Dark at 960 × 640.

## Completion record

Delivered in Frame 0.2.0 (build 2), installed in Applications. Replaced fixed/adaptive color mixing with paired NSColor providers across SwiftUI and AppKit. There is no production theme preference or toolbar control.

Verification: 30-test suite passed; native Light/Dark screenshots and live switches passed. [Delivery evidence](../system-specs/verification-2026-10-21.md) includes the installed artifact and recoverable prior app.

Deviation/follow-up: the primary workspace screenshot matrix is complete; every error/notice/recovery state and OS-scheduled automatic switching were not manually exercised. Shared palette tests cover their foreground/surface pairs, not every rendered state.
