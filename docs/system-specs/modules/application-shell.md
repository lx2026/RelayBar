# Application Shell

RelayBar is a native SwiftUI `MenuBarExtra` application for macOS 13 or newer.

## Contract

- The app runs as a menu-bar accessory with no Dock icon (`LSUIElement`).
- The popover is a 380 × 440 point window containing the tunnel list, the profile editor, or the settings screen.
- The profile editor and Settings use one viewport-constrained vertical-scroll
  container. Its document width is the viewport minus balanced 16-point
  insets, so focus rings and intrinsically wide controls cannot create a
  horizontal scroll range or shift content against an edge. When an
  always-visible scroller narrows the view, content keeps its leading inset.
  Field labels appear once; native picker labels are hidden where a custom
  field label is present.
- Popover chrome and content share a 16-point inset. Icon buttons share one
  28-point circular shape; only the action most likely wanted next is filled
  with the accent colour, and never while it is unavailable.
- The menu-bar icon indicates whether any tunnel is starting, retrying, or running.
- The list header reports the active tunnel count.
- A labeled Remote Files row below the tunnel list opens or focuses one separate window.
- Settings has a Plugins row whose button opens or focuses the Plugins window described in [Composition](../shared/composition.md).
- The Remote Files row opens one 920 × 600 point resizable split workspace with
  a 760 × 440 minimum. Its hideable leading sidebar uses a 210 point minimum,
  250 point ideal, and 360 point maximum while the detail retains at least 430
  points. Entering preview grows an undersized window to at least 980 × 640 and
  never shrinks a user-enlarged window.
- A gear button in the list header opens an in-popover settings screen with the editor's back-navigation idiom; Escape returns to the list.
- The settings screen's Launch at Login toggle registers or unregisters the main app as the current user's login item through `SMAppService.mainApp` — no helper executable, launch daemon, elevated privilege, or separate settings window.
- The General card's second row is **Automatic Updates**. It controls
  the preference document's scheduled-check choice, imported once from Sparkle's
  native preference and applied only after a successful save. It defaults off, checks at
  a seven-day interval when enabled, and cannot enable automatic download or
  installation. Settings and application activation do not initiate checks.
- The General card's **SSH Retry Limit** stepper sets 0–100 retries globally
  for forwarding profiles, defaulting to 10. Its caption explains that 0
  disables retries; supporting text describes exponential waiting from 5
  seconds to 5 minutes and a reset after 1 minute connected. The value is
  persisted immediately and exposed to accessibility as a retry count or Off.
- The system login-item status is authoritative; no second enabled flag is persisted. Approval-required and not-found states keep the toggle off, while an operation error remains visible without overriding the system-reported toggle state, so failed changes stay truthful and retryable. Approval-required links to the macOS Login Items settings, and the displayed state refreshes when the app becomes active.
- A login launch opens the same menu-bar-only app; saved forwarding profiles stay stopped until the user starts them.
- A quiet Settings footer reads version and build from the running bundle,
  offers a non-shifting copy confirmation, and opens the canonical website and
  GitHub repository. Its **Check for Updates…** action exposes only transient
  checking/current/error text and starts one user-initiated Sparkle check; a
  found update continues in that same check's standard Sparkle window. Closing
  Settings clears inline claims.
- Updater state never changes the menu-bar icon, tunnel-list header, Settings
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
- `RelayBarRootView` owns navigation and presentation.
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
