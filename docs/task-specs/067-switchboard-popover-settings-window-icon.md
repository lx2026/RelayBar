# Switchboard popover, Settings window and new icon

Status: Implemented — 2026-11-16. Automated checks pass; [verification](../verification/067-switchboard-popover-settings-window-icon.md). Awaiting the owner's hand check in the real app. The owner reviewed three mocked directions after trying 2.0.0 and chose the "Switchboard" popover, Settings as a window, and the "Route" icon.

## Outcome

RelayBar's popover lists each tunnel as a compact two-line row with a switch, Settings opens in its own window sized to its content, no popover page is narrowed or cropped by the system scroll bar, and the app has a new icon and a menu-bar glyph that tells idle, active and failed apart.

## Delivery Boundary

RelayBar only: the popover's header, list, group headers, rows, footer and scrolling; the header bar of the profile editor; Settings; the app icon; the menu-bar glyph. Tunnel behaviour, stored data, the row menu, the profile editor's form, Remote Files, Plugins, Frame and the shared packages do not change. The group menu gains Start All and Stop All, because its header now shows only one of them. No version change, install, push or release.

## Work

- Popover, still 380 × 440 points:
  - A 44-point header with the app name, the active count, an issue count when any tunnel has failed, and Settings and Add buttons. The app mark is removed.
  - Flat 46-point rows without cards: a status glyph that differs by shape as well as colour, the name, and one second line holding the port mapping and either the host or the current status. A switch starts and stops the tunnel. Open in Browser and the row menu appear on hover and keyboard focus, and the row menu is also the right-click menu.
  - Retry and failure text keeps its full wording in a tooltip.
  - Each named group header offers one action, Start All or Stop All, chosen from the group's state; its menu holds both, with the other group actions.
  - A 40-point footer with Remote Files and Quit. "Uses macOS SSH" moves to Settings.
- Scrolling: popover scroll views use the thin overlay indicator whatever the system "Show scroll bars" setting, so content is never laid out wider than its viewport, and the list fades at its lower edge.
- The profile editor takes the same 44-point header bar; its form is unchanged.
- Settings becomes a 480-point-wide window that fits its content without scrolling: grouped General rows, a Previews table with one "Size limit" heading, the Frame access row when present, and an About row with the version, Check for Updates, "Uses macOS SSH" and the links. The gear button and Command-comma open or focus it.
- The app icon becomes the Route mark, drawn by a script kept in the repository, with a simplified drawing at the smallest sizes.
- The menu-bar glyph is the Route mark as a template image: dimmed when idle, solid when any tunnel is starting, retrying or running, and followed by an exclamation mark when any tunnel has failed.

## Acceptance

- Captures of the popover (mixed states, grouped and flat, hovered row, overflowing list), the profile editor header and the Settings window exist in light and dark appearance, and match the chosen mocks in layout and proportion.
- With "Show scroll bars" set to Always, the list, the editor and Settings show no content cut off at the right edge.
- Six tunnel rows with two group headers are fully visible in the popover without scrolling.
- Settings shows every row, including the Frame access row and a Launch at Login note, without scrolling.
- The menu-bar glyph shows the three states, and the status item's accessibility label states the active and failed counts.
- The icon renders from the script to every size in the asset catalog, and the unsigned Release build carries it.
- `scripts/test.sh`, the unsigned Release build and `git diff --check` pass; the affected system specs describe the new behaviour; a verification record lists what changed and what still needs a hand check.
