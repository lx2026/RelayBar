# Application Shell

RelayBar is a native SwiftUI `MenuBarExtra` application for macOS 13 or newer.

## Contract

- The app runs as a menu-bar accessory with no Dock icon (`LSUIElement`).
- The popover is a 380 × 440 point window containing the tunnel list or the
  profile editor. Its size, header height and icon-button shape are defined
  once, in `RelayBarPopoverLayout`.
- The popover, the Settings window, the Remote Files window and the Plugins
  window draw with the shared house palette ([House style](../shared/house-style.md)):
  paper behind the popover, ink and muted text, line hairlines and fill for
  hover. Paper Appearance, on by default, chooses the warm paper form or the
  standard macOS colours; switching it redraws open windows at once and keeps
  every view's state, on macOS 13 too.
- Each screen starts with a 44-point header bar and a hairline below it. The
  list's header has "RelayBar" in 13-point semibold 16 points from the leading
  edge, then a 12-point secondary summary ("All stopped" when no tunnel is
  starting, retrying or running, "N active" otherwise, nothing when there are
  no tunnels), then, when any tunnel has failed, a red warning triangle with
  "1 issue" or "N issues". Settings (gear, Command-comma) and Add (plus) sit 9
  points from the trailing edge. The title, summary and issue count form one
  accessibility header element labelled, for example, "RelayBar, 5 active, 1
  issue". The profile editor's header has the Back button (`chevron.left`) 9
  points from the leading edge and its title in 13-point semibold.
- Header icon buttons are 26-point rounded squares (radius 7) with no resting
  fill, a faint fill under the pointer and a stronger one while pressed. A
  row's buttons are 24-point versions of the same shape. The footer's text
  buttons use the same shape and fills at 26 points high. Hover fills and
  hover-revealed controls are cleared when their window stops being key, so
  nothing is still highlighted when the popover next opens.
- The list's footer is 40 points including the hairline above it: **Remote
  Files…** (folder glyph and text) at the leading edge and **Quit** in
  secondary text at the trailing edge, each inset 8 points.
- The list has no cards or dividers. Its content is inset 4 points at the top,
  6 at each side and 16 at the bottom. Named group headers are 26 points high
  with 6 points of extra space above every header but the first; rows are 46
  points high with an 8-point corner radius, and the row under the pointer has
  a faint rounded fill. The list fades out over its last 16 points through an
  alpha mask; at the end of the list the bottom inset keeps the last row clear
  of the fade. Six rows and two group headers fit without scrolling. Row and
  group-header contents are described in
  [Tunnel management](tunnel-management.md).
- Every popover scroll view (the list and the profile editor) scrolls only
  vertically. It uses the thin overlay scroller whatever the system "Show
  scroll bars" setting, and applies it again when
  `NSScroller.preferredScrollerStyleDidChangeNotification` is posted and
  whenever its document is laid out, so the viewport is normally the full
  width. Under either scroller style the document is exactly as wide as the
  clip view: the popover's width less the width the scroller is measured to
  take, which is zero on the overlay scroller. Its content is that width
  minus balanced insets (16 points in the editor, 6 in the list) and never
  wider, so long text, focus rings and intrinsically wide controls cannot
  create a horizontal scroll range or shift content against an edge, and on
  a legacy scroller the content narrows rather than running underneath it.
  The backing scroll view has no horizontal scroller or horizontal
  elasticity. It corrects horizontal drift once per bounds change. Nested
  notifications during that correction leave the clip view alone. Field labels
  appear once; native picker labels are hidden where a custom field label is
  present. The editor's form keeps its cards and its circular rule buttons.
- The menu-bar glyph is the Route mark, drawn in code as an 18 × 18 point
  template image: at 45% alpha when no tunnel is starting, retrying, running or
  failed; at full strength when any tunnel is starting, retrying or running;
  and, when any tunnel has failed, at full strength followed by an exclamation
  mark (25 × 18 points). A failure takes precedence. The status item shows the
  icon only; its accessibility label names the app and the counts, for example
  "RelayBar, 2 tunnels active, 1 failed", and is carried by the image's
  accessibility description, which is what the menu bar reads.
- **Remote Files…** in the list's footer opens or focuses one separate window.
- Settings has a Plugins row whose button opens or focuses the Plugins window described in [Composition](../shared/composition.md).
- Remote Files opens one 920 × 600 point resizable split workspace with
  a 760 × 440 minimum. Its hideable leading sidebar uses a 210 point minimum,
  250 point ideal, and 360 point maximum while the detail retains at least 430
  points. Entering preview grows an undersized window to at least 980 × 640 and
  never shrinks a user-enlarged window.
- The gear button in the list header, or Command-comma while the popover is
  open, opens the **RelayBar Settings** window, or focuses it when it is already
  open, and activates the app. The window is titled and closable, not
  resizable, 480 points wide and always exactly as tall as its content: it
  grows and shrinks, keeping its title bar in place, when a Launch at Login
  note, the Frame access box or an update status line appears, and it never
  scrolls. Command-W and Escape close it. It is created the first time it
  opens, not created when the app runs without windows, and closed on quit.
- Settings lists, top to bottom: a General box (Launch at Login, Automatic
  Updates, SSH Retry Limit, Plugins), the retry caption, a Previews box with
  one "Size limit" heading over the pop-up column, the Frame access box while
  Frame has access, an About box, and a bottom row with "Uses macOS SSH" and
  the Website and GitHub links. Boxes are rounded 10-point cards with a
  hairline edge on the panel-coloured window; rows are inset 14 points with
  dividers inset on both sides; every toggle is a small switch.
- The Launch at Login switch registers or unregisters the main app as the current user's login item through `SMAppService.mainApp` — no helper executable, launch daemon or elevated privilege. Its approval, not-found and error notes appear under its description.
- The General box's second row is **Automatic Updates**. It controls
  the preference document's scheduled-check choice, imported once from Sparkle's
  native preference and applied only after a successful save. It defaults off, checks at
  a seven-day interval when enabled, and cannot enable automatic download or
  installation. Settings and application activation do not initiate checks.
- The General box's **SSH Retry Limit** number field and stepper set 0–100
  retries globally for forwarding profiles, defaulting to 10. Its caption
  explains that 0 disables retries; supporting text describes exponential
  waiting from 5 seconds to 5 minutes and a reset after 1 minute connected. A
  stepper click is persisted immediately; a typed number is persisted only
  when committed with Return or by leaving the field, clamped into 0–100, so
  intermediate digits never reach running tunnels. Closing the window or
  switching away from it ends editing first, so a typed number is kept. The
  value is exposed to accessibility as a retry count or Off.
- Each Previews row has the format's name, a 96-point size-limit pop-up and a
  switch. A format that is off shows its name in secondary text and disables
  its pop-up. Each pop-up's accessibility label names its format and "size
  limit".
- The system login-item status is authoritative; no second enabled flag is persisted. Approval-required and not-found states keep the toggle off, while an operation error remains visible without overriding the system-reported toggle state, so failed changes stay truthful and retryable. Approval-required links to the macOS Login Items settings, and the displayed state refreshes when the app becomes active.
- A login launch opens the same menu-bar-only app; saved forwarding profiles stay stopped until the user starts them.
- The About box shows the app icon, the name, and a version line read from the
  running bundle ("Version 2.0.0 (22)", "Version 2.0.0", "Build 22" or
  "Version unavailable") with a copy button that copies the full string, such
  as "RelayBar 2.0.0 (22)", and shows a checkmark for 1.5 seconds. Its
  **Check for Updates…** button exposes only transient
  checking/current/error text, on a line under the version, and starts one
  user-initiated Sparkle check; a found update continues in that same check's
  standard Sparkle window. The bottom row's links open the canonical website
  and GitHub repository. Closing Settings clears inline claims.
- Updater state never changes the menu-bar glyph, tunnel-list header, Settings
  button, or list content. Before an update-driven relaunch, active tunnels
  produce a modal decision naming their count: stop them and install, or keep
  them running and defer installation until they are stopped. A deferred
  install remains visible in Settings with its current tunnel count, and the
  installer is resumed only after termination callbacks confirm every managed
  SSH master and control helper has exited. Stop sends SIGTERM, then escalates
  a surviving child to SIGKILL after a bounded grace period so update relaunch,
  quit, logout, and shutdown cannot wait indefinitely.
- A maintainer-only `--maintainer-update-feed` launch argument can override the
  bundled production feed only for an explicit-port, plain-HTTP loopback URL
  on `127.0.0.1`, `localhost`, or `::1`. The override is process-scoped and is
  not persisted. An invalid requested override prevents the updater from
  starting; an ordinary launch uses the signed HTTPS production feed.
- Quit stops all managed SSH processes before terminating the app.
- Only Debug builds recognize the explicit preview-window and Remote Files
  preview launch modes. Release builds always enable normal configuration
  persistence and bridge startup, regardless of preview-looking arguments or
  the containing folder's name.

## Ownership

- `RelayBarApp` owns application lifecycle.
- `RelayBarRootView` owns popover navigation between the list and the editor.
- `RelaySettingsWindowController` owns the Settings window; `RelayBarComposition`
  creates it on first use and releases it when the app stops.
- `StatusItemGlyph` draws the menu-bar glyph and derives its state and
  accessibility label from the tunnels' phases.
- `RelayBarComposition` supplies the tunnel store and owns the feature runtime;
  each profile context owns its process lifecycle.
- `LaunchAtLoginModel` owns login-item state behind the injected `LoginItemServicing` boundary.
- `UpdateModel` owns the Settings-facing state behind a feature-owned
  `UpdateServicing` boundary. The Xcode app supplies Sparkle; SwiftPM tests
  supply an inert or injected service and cannot contact the update feed.
- `ApplicationAboutModel` owns bundle metadata, version copying, and canonical
  project-link routing.
- The remote-window feature supplies `RemoteFilesWindowController` and its
  isolated model, services and preview registrations.
