import AppKit
import Composition
import CompositionUI
import SwiftUI
import XCTest
@testable import FrameKit

/// Writes offscreen PNGs of Frame's Plugins window, drawn from the running feature tree, when
/// `FRAME_SNAPSHOT_DIR` is set; skipped otherwise.
@MainActor
final class PluginsWindowSnapshotTests: XCTestCase {
    func testWritesPluginsWindowSnapshots() async throws {
        guard let path = ProcessInfo.processInfo.environment["FRAME_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set FRAME_SNAPSHOT_DIR to write Plugins window snapshots.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        QuietWindow.prepareTestProcess()
        // Render as on a trackpad Mac: overlay scrollers, so no legacy scroller corner is drawn.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        // Without RelayBar: the remote half of the tree waits for a session.
        let alone = FrameComposition(preferencesURL: temporaryPreferences())
        try await alone.start()
        await alone.runtime.settled()
        try write(alone, selection: nil, appearance: .aqua, to: directory.appendingPathComponent("frame-plugins-without-relaybar-light.png"))
        try write(alone, selection: "remote/source", appearance: .aqua,
                  to: directory.appendingPathComponent("frame-plugins-without-relaybar-waiting-selected-light.png"))
        await alone.stop()

        // With a session: both halves run, and Prompt Search is mounted in each.
        let connected = FrameComposition.fixture(preferencesURL: temporaryPreferences(), library: FixtureRemoteLibrary())
        try await connected.start()
        await connected.runtime.settled()
        try write(connected, selection: "remote/prompt-search", appearance: .aqua,
                  to: directory.appendingPathComponent("frame-plugins-connected-search-selected-light.png"))
        try write(connected, selection: "remote/prompt-search", appearance: .darkAqua,
                  to: directory.appendingPathComponent("frame-plugins-connected-search-selected-dark.png"))
        try await connected.setPlugin(FramePlugins.promptSearch, enabled: false)
        await connected.runtime.settled()
        try write(connected, selection: nil, appearance: .aqua,
                  to: directory.appendingPathComponent("frame-plugins-connected-search-off-light.png"))
        await connected.stop()
    }

    private func temporaryPreferences() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FramePluginsSnapshot-\(UUID())", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return folder.appendingPathComponent("preferences.json")
    }

    private func write(_ composition: FrameComposition, selection: String?, appearance: NSAppearance.Name, to url: URL) throws {
        let composer = PluginComposer(runtime: composition.runtime, plugins: FramePlugins.all,
                                      isEnabled: { composition.isPluginEnabled($0) },
                                      setEnabled: { try await composition.setPlugin($0, enabled: $1) })
        composer.selection = selection
        let bounds = NSRect(x: 0, y: 0, width: 1180, height: 720)
        let host = NSHostingView(rootView: PluginComposerView(composer: composer)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = QuietWindow(size: bounds.size)
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
