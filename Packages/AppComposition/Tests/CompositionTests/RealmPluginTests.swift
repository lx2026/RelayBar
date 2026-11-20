import Composition
@testable import CompositionUI
import XCTest

@MainActor
final class RealmPluginTests: XCTestCase {
    func testRelativeMembershipTracksEachRealmAndPrunesItsSubtree() async throws {
        let runtime = FeatureRuntime()
        let log = Log()
        let plugin = PluginDescriptor(id: "preview", title: "Preview", summary: "", symbol: "doc",
                                      isOnByDefault: true, realmRelativeFeatures: ["readers/preview"])
        func readers(_ host: String) -> FeatureNode {
            FeatureNode("readers") { Probe(name: "readers", log: log) } children: {
                FeatureNode("preview") { Probe(name: host, log: log) } children: {
                    FeatureNode("child") { Probe(name: "child", log: log) }
                }
            }
        }
        let tree = [readers("outside"), FeatureNode.realm("alpha") {
            readers("alpha")
            FeatureNode.realm("beta") { readers("beta") }
        }]
        let composer = PluginComposer(runtime: runtime, plugins: [plugin], isEnabled: { _ in true }, setEnabled: { _, _ in })
        try runtime.set(tree)
        await runtime.settled()
        for realm in ["alpha", "alpha/beta"] {
            let node = try XCTUnwrap(composer.node(realm + "/readers/preview"))
            XCTAssertEqual(composer.plugin(owning: node), plugin)
        }
        XCTAssertEqual(log.count("alpha"), 1)
        XCTAssertEqual(log.count("beta"), 1)
        XCTAssertNil(composer.plugin(owning: try XCTUnwrap(composer.node("readers/preview"))))
        composer.reveal(plugin)
        XCTAssertEqual(composer.selection, "alpha/readers/preview")
        let failed = FeatureGraph.Node(id: "alpha/beta/readers/preview", name: "preview", parent: "alpha/beta/readers",
                                       container: "alpha/beta", isContainer: false, phase: .failed("unavailable"),
                                       generation: 1, needs: [], offers: [])
        let snapshot = PluginComposer(graph: FeatureGraph(nodes: runtime.graph.nodes.map { $0.id == failed.id ? failed : $0 }, edges: []),
                                      plugins: [plugin], enabled: [plugin.id])
        XCTAssertEqual(snapshot.trouble(of: plugin), failed)
        try runtime.set(tree.excluding(plugins: [plugin]) { _, realm in realm == "alpha" })
        await runtime.settled()
        XCTAssertNil(composer.node("alpha/readers/preview"))
        XCTAssertEqual(composer.node("alpha/beta/readers/preview")?.phase, .active)
        composer.reveal(plugin)
        XCTAssertEqual(composer.selection, "alpha/beta/readers/preview")
        XCTAssertEqual(log.count("beta"), 1)
        try runtime.set(tree.excluding(plugins: [plugin]))
        await runtime.settled()
        XCTAssertNil(composer.selection)
        XCTAssertEqual(runtime.graph.nodes.map(\.id), ["readers", "readers/preview", "readers/preview/child",
                                                      "alpha", "alpha/readers", "alpha/beta", "alpha/beta/readers"])
        XCTAssertEqual(log.count("outside"), 1)
        await runtime.shutdown()
    }
}
