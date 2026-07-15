import AppKit
import SwiftUI

@main
@MainActor
struct RelayBarApp: App {
    @NSApplicationDelegateAdaptor(RelayBarAppDelegate.self) private var appDelegate
    @StateObject private var store = TunnelStore.shared

    var body: some Scene {
        MenuBarExtra {
            RelayBarRootView()
                .environmentObject(store)
        } label: {
            Label("RelayBar", systemImage: store.runningCount > 0
                  ? "arrow.left.arrow.right.circle.fill"
                  : "arrow.left.arrow.right.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class RelayBarAppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--preview-window") else { return }

        let rootView = RelayBarRootView()
            .environmentObject(TunnelStore.shared)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "RelayBar Preview"
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        previewWindow = window
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        TunnelStore.shared.stopAll()
    }
}
