# Task 022 — Launch at Login

Status: Complete

Created: 2026-07-26

Issue: [#9 — Add the option to automatically run at startup](https://github.com/lx2026/RelayBar/issues/9)

## Outcome

Let the current user opt in to launching RelayBar automatically when they log
in to macOS. Launching RelayBar must not start saved forwarding profiles.

## Delivery Boundary

- Use `SMAppService.mainApp` on the existing macOS 13 minimum deployment target.
- Expose a native **Launch at Login** control on an in-popover settings screen
  reachable from the tunnel-list header, without adding a helper executable,
  installer, Dock icon, or separate settings window.
- Treat the system service status as authoritative; do not persist a second
  enabled flag in `UserDefaults`.
- Surface registration failures and approval-required state without claiming
  the option is enabled.
- Do not create a launch daemon, request elevated privileges, or automatically
  start, stop, or reconnect any forwarding profile.

## Work

- Add a small service wrapper that reads `SMAppService.mainApp.status` and
  registers or unregisters the main application.
- Represent not-registered, enabled, approval-required, not-found, and error
  states in testable application state.
- Add a settings screen to the popover, opened from the list header, and place
  the control there with keyboard and VoiceOver support and a path to the
  macOS Login Items settings when user approval is required.
- Refresh the displayed state after the app becomes active so changes made in
  System Settings are reflected.
- Add focused tests through an injected service boundary; unit tests must not
  alter the developer machine's real login-item registration.
- Update the application-shell and verification system specs.

## Acceptance

- With the service not registered, enabling **Launch at Login** registers the
  main RelayBar app and the control reflects the resulting system status.
- Disabling the option unregisters future launches without quitting the current
  RelayBar process.
- A change made in System Settings is reflected when RelayBar becomes active
  again.
- Approval-required and registration-error states remain visible and
  actionable; they do not silently flip the control to enabled.
- A login launch opens RelayBar as the same menu-bar-only app and leaves every
  saved forwarding profile stopped.
- The settings screen and its control fit the 380 × 440 popover in light and
  dark appearances and are operable with keyboard navigation and VoiceOver.
- Focused tests, `swift test -Xswiftc -warnings-as-errors`, the Release build,
  and `git diff --check` pass.
- A signed packaged build is manually verified for enable, login relaunch,
  disable, and System Settings state synchronization before completion.
- No release or deployment occurs without separate approval.

## Evidence (2026-07-26)

- `LaunchAtLogin.swift` wraps `SMAppService.mainApp` behind `LoginItemServicing`;
  `LaunchAtLoginModel` holds the five testable states and preserves the
  authoritative system status when surfacing operation errors, keeping failed
  changes truthful and retryable. A gear button in the list header opens
  `SettingsView`, whose General card holds the toggle with an
  approval-required link to Login Items settings; state refreshes on appear
  and on `didBecomeActive`, and no second flag is stored in `UserDefaults`.
- `LaunchAtLoginTests` covers status mapping, register/unregister routing,
  approval-required and error surfacing, authoritative toggle state and retry
  after failed operations, refresh after external System Settings changes,
  and settings-link routing — all through the injected spy, never the real
  registration.
- `swift test -Xswiftc -warnings-as-errors` (180 tests), the Xcode Release
  build (strict concurrency, warnings as errors), `plutil -lint
  Packaging/Info.plist`, and `git diff --check` pass.
- Offscreen snapshots (`settings-*` and `settings-login-approval-*`) verify
  the settings screen and its tallest caption at 380 × 440 in light and dark;
  `tunnel-list-*` confirms the list header and footer.
- The user manually tested the installed Developer-ID-signed, Apple-notarized
  build and confirmed the Launch at Login issue is fixed. A second explicitly
  approved notarized build was then accepted, stapled, and Gatekeeper-verified
  before pull-request preparation.
