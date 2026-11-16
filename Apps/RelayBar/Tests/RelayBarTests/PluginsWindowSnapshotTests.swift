import AppKit
import Composition
import CompositionUI
import SwiftUI
import XCTest
@testable import RelayBar

/// Writes offscreen PNGs of RelayBar's Plugins window, drawn from the running feature tree, when
/// `RELAYBAR_SNAPSHOT_DIR` is set; skipped otherwise.
@MainActor
final class PluginsWindowSnapshotTests: XCTestCase {
    func testWritesPluginsWindowSnapshots() async throws {
        guard let path = ProcessInfo.processInfo.environment["RELAYBAR_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set RELAYBAR_SNAPSHOT_DIR to write Plugins window snapshots.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // Render as on a trackpad Mac: overlay scrollers, so no legacy scroller corner is drawn.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        let suite = "RelayBarPluginsSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let app = RelayBarComposition(defaults: defaults, startsBridge: false, showsWindows: false,
            makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
            makeTunnels: { TunnelStore(defaults: defaults, persistsRetryLimit: false) },
            makeFileService: { SnapshotFileService() },
            makeUpdates: { _ in UnavailableUpdateService() }, loginService: LoginItemServiceSpy(status: .notRegistered),
            recoveryEvents: SnapshotRecoveryEvents(), serviceProbe: SnapshotProbe(), frameInstalled: false)
        addTeardownBlock {
            await app.stop()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        await app.start()
        XCTAssertNil(app.errorMessage)

        // As installed without Frame: Reconnect on Wake on, Service Labels and Open in Frame off, Remote Files closed.
        try write(app, selection: nil, appearance: .aqua, to: directory.appendingPathComponent("relaybar-plugins-defaults-light.png"))

        // Both plugins on, with the Remote Files window's features mounted.
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        try await app.setRemoteFilesOpen(true)
        await app.runtime.settled()
        try write(app, selection: nil, appearance: .aqua, to: directory.appendingPathComponent("relaybar-plugins-all-on-light.png"))
        try write(app, selection: "services", appearance: .aqua,
                  to: directory.appendingPathComponent("relaybar-plugins-services-selected-light.png"))
        try write(app, selection: "tunnels", appearance: .darkAqua,
                  to: directory.appendingPathComponent("relaybar-plugins-tunnels-selected-dark.png"))
        try await app.setRemoteFilesOpen(false)
    }

    private func write(_ app: RelayBarComposition, selection: String?, appearance: NSAppearance.Name, to url: URL) throws {
        let composer = PluginComposer(runtime: app.runtime, plugins: app.plugins,
                                      isEnabled: { app.isPluginEnabled($0) },
                                      setEnabled: { try await app.setPlugin($0, enabled: $1) })
        composer.selection = selection
        let bounds = NSRect(x: 0, y: 0, width: 1180, height: 720)
        let host = NSHostingView(rootView: PluginComposerView(composer: composer)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2360, pixelsHigh: 1440,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// Never delivers an event.
private struct SnapshotRecoveryEvents: RecoveryEvents {
    func events() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}

/// Answers every probe without a network request.
private struct SnapshotProbe: ServiceProbing {
    func probe(_ url: URL) async -> ServiceLabel {
        ServiceLabel(name: "ComfyUI", isResponding: true)
    }
}

/// A file service that lists nothing and is never asked for a file.
private actor SnapshotFileService: RemoteFileServing {
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        []
    }

    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {}

    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        throw RemoteFileError.previewTooLarge
    }
}
