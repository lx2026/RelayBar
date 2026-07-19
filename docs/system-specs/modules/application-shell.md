# Application Shell

RelayBar is a native SwiftUI `MenuBarExtra` application for macOS 13 or newer.

## Contract

- The app runs as a menu-bar accessory with no Dock icon (`LSUIElement`).
- The popover is a 380 × 440 point window containing the tunnel list or editor.
- The menu-bar icon indicates whether any tunnel is starting, retrying, or running.
- The list header reports the active tunnel count.
- Quit stops all managed SSH processes before terminating the app.

## Ownership

- `RelayBarApp` owns application lifecycle.
- `RelayBarRootView` owns navigation and presentation.
- `TunnelStore.shared` owns tunnel and process state.
