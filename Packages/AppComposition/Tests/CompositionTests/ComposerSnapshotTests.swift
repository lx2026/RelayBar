import AppKit
import Composition
import CompositionFixtures
import CompositionUI
import SwiftUI
import XCTest

/// Writes offscreen PNGs of the composer at 2x when `COMPOSITION_SNAPSHOT_DIR` is set; skipped otherwise.
@MainActor
final class ComposerSnapshotTests: XCTestCase {
    func testWritesComposerSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["COMPOSITION_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set COMPOSITION_SNAPSHOT_DIR to write composer snapshots.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        QuietWindow.prepareTestProcess()
        // Render as on a trackpad Mac: overlay scrollers, so no legacy scroller corner is drawn.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let cases: [(name: String, selection: String?)] = [("nothing-selected", nil), ("remote-selected", "remote/source")]
        let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for shot in cases {
            for look in appearances {
                let data = try render(selection: shot.selection, appearance: look.appearance)
                try data.write(to: directory.appendingPathComponent("composer-\(shot.name)-\(look.name).png"))
            }
        }
    }

    private func render(selection: String?, appearance: NSAppearance.Name) throws -> Data {
        let composer = PluginComposer(graph: ComposerFixture.graph, plugins: ComposerFixture.plugins,
                                      enabled: ComposerFixture.enabled, dependents: ComposerFixture.dependents)
        composer.selection = selection
        let bounds = NSRect(x: 0, y: 0, width: 1180, height: 640)
        let host = NSHostingView(rootView: PluginComposerView(composer: composer)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = QuietWindow(size: bounds.size)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2360, pixelsHigh: 1280,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

/// A static graph shaped like Frame's tree, shared by the layout tests and the snapshots.
/// The link runs without a session, so the whole remote realm waits; one plugin feature has failed.
enum ComposerFixture {
    static let plugins = [
        PluginDescriptor(id: "prompt-search", title: "Prompt search", summary: "Find images by the prompt saved beside them.",
                         symbol: "text.magnifyingglass", isOnByDefault: true, features: ["prompt-search", "remote/prompt-search"]),
        PluginDescriptor(id: "palette", title: "Palettes", summary: "Group images by their main colors.",
                         symbol: "paintpalette", isOnByDefault: true, features: ["palette"]),
        PluginDescriptor(id: "places", title: "Places", summary: "Show images that carry a location on a map.",
                         symbol: "map", isOnByDefault: false, features: ["places"])
    ]
    static let enabled: Set<String> = ["prompt-search", "palette"]
    static let dependents: [String: [String]] = ["prompt-search": [], "remote/prompt-search": [], "palette": []]

    static let graph: FeatureGraph = {
        let isolated: Set<String> = ["MediaSource", "Thumbnails", "Metadata", "Previews", "PlaybackPreviews"]
        let media: [(name: String, needs: [String], offers: [String])] = [
            ("thumbnails", ["MediaSource"], ["Thumbnails"]),
            ("metadata", ["MediaSource"], ["Metadata"]),
            ("previews", ["MediaSource"], ["Previews", "PlaybackPreviews"]),
            ("preview.image", ["Previews", "Thumbnails", "MediaSource"], [])
        ]
        let root: [(name: String, needs: [String], offers: [String])] = [("access", [], ["LocalAccess", "MediaSource"])]
            + media
            + [("preview.markdown", ["Previews", "Documents", "LocalAccess", "MediaSource"], []),
               ("playback", ["LocalAccess", "Metadata"], ["Playback"]),
               ("documents", [], ["Documents"]),
               ("prompt-search", ["MediaSource", "Metadata"], []),
               ("palette", ["Thumbnails"], []),
               ("relay.link", [], ["RelaySession"])]
        let remote: [(name: String, needs: [String], offers: [String])] = [("source", ["RelaySession"], ["MediaSource"])]
            + media
            + [("prompt-search", ["MediaSource", "Metadata"], [])]

        var nodes: [FeatureGraph.Node] = []
        for spec in root {
            let phase: FeaturePhase = spec.name == "palette" ? .failed("Could not open the palette index.") : .active
            nodes.append(FeatureGraph.Node(id: spec.name, name: spec.name, parent: nil, container: nil, isContainer: false,
                                           phase: phase, generation: 1, needs: spec.needs, offers: spec.offers))
        }
        nodes.append(FeatureGraph.Node(id: "remote", name: "remote", parent: nil, container: nil, isContainer: true,
                                       phase: .active, generation: 1, needs: [], offers: []))
        for spec in remote {
            nodes.append(FeatureGraph.Node(id: "remote/\(spec.name)", name: spec.name, parent: "remote", container: "remote",
                                           isContainer: false, phase: .pending(""), generation: 0,
                                           needs: spec.needs, offers: spec.offers))
        }

        func provider(of service: String, for consumer: FeatureGraph.Node) -> String? {
            let realm = consumer.container != nil && isolated.contains(service) ? consumer.container : nil
            return nodes.first { $0.container == realm && $0.offers.contains(service) }?.id
        }
        var edges: [FeatureGraph.Edge] = []
        for node in nodes {
            for service in node.needs {
                let source = provider(of: service, for: node)
                let live = source.flatMap { id in nodes.first { $0.id == id } }?.phase == .active && service != "RelaySession"
                edges.append(FeatureGraph.Edge(service: service, provider: source, consumer: node.id, isSatisfied: live))
            }
        }
        // Each waiting feature names its first unmet need, as the runtime does.
        nodes = nodes.map { node in
            guard case .pending = node.phase, let unmet = edges.first(where: { $0.consumer == node.id && !$0.isSatisfied }) else {
                return node
            }
            return FeatureGraph.Node(id: node.id, name: node.name, parent: node.parent, container: node.container,
                                     isContainer: false, phase: .pending("Needs \(unmet.service) from \(unmet.provider ?? "-")"),
                                     generation: node.generation, needs: node.needs, offers: node.offers)
        }
        return FeatureGraph(nodes: nodes, edges: edges)
    }()
}
