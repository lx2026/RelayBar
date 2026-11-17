import AppKit
import Composition
import CompositionUI
import HouseStyle
import SwiftUI

/// RelayBar's plugin catalog: the optional features a person can switch in the Plugins window.
enum RelayPlugins {
    static let recovery = PluginDescriptor(
        id: "recovery",
        title: "Reconnect on Wake",
        summary: "Retries waiting tunnels as soon as the Mac wakes or the network returns.",
        symbol: "arrow.clockwise.circle",
        isOnByDefault: true,
        features: ["recovery"]
    )

    static let services = PluginDescriptor(
        id: "services",
        title: "Service Labels",
        summary: "Shows what is answering on each forwarded web port.",
        symbol: "tag",
        isOnByDefault: false,
        features: ["services"]
    )

    /// Until the person chooses, on only if Frame was installed when RelayBar launched.
    static func frame(installed: Bool) -> PluginDescriptor {
        PluginDescriptor(
            id: "frame",
            title: "Open in Frame",
            summary: "Opens remote folders in the Frame viewer and lets Frame reach them through RelayBar.",
            symbol: "photo.on.rectangle",
            isOnByDefault: installed,
            features: ["frame.host", "remote.files/open-in-frame"]
        )
    }

    /// The palette's form, shared with Frame.
    static let paperAppearance = PaperAppearance.plugin

    static func all(frameInstalled: Bool) -> [PluginDescriptor] {
        [recovery, services, frame(installed: frameInstalled), paperAppearance]
    }
}

/// The Plugins window. It hosts the shared composer and stays until the app stops.
@MainActor
final class RelayPluginsWindowController {
    let window: NSWindow

    init(composer: PluginComposer) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Plugins"
        window.contentMinSize = NSSize(width: 900, height: 540)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PluginComposerView(composer: composer))
        window.center()
        window.setFrameAutosaveName("RelayBarPlugins")
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }
}
