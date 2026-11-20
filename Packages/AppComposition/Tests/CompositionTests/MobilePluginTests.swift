import Composition
@testable import CompositionUI
import XCTest

private enum Route: ServiceKey { typealias Value = Int }

private struct Router: Feature {
    @Need(Connection.self) var session
    @Offer(Route.self) var route
    @MainActor func run(_ context: FeatureContext) async throws { route.set(session.value) }
}

private struct Page: Feature {
    @Need(Route.self) var route
    @MainActor func run(_ context: FeatureContext) async throws {}
}

/// Two independent copies of the same plugin, one with a connected session.
@MainActor
enum MobilePluginFixture {
    static let network = PluginDescriptor(id: "network", title: "The Host’s Network",
                                          summary: "Opens other machines the host can reach.",
                                          symbol: "network", isOnByDefault: false,
                                          realmRelativeFeatures: ["routes"])
    static let catalog = [
        PluginDescriptor(id: "notebook", title: "Notebook Preview", summary: "Shows read-only notebooks.",
                         symbol: "book", isOnByDefault: true),
        network,
        PluginDescriptor(id: "table", title: "Table Preview", summary: "Shows CSV and TSV files as tables.",
                         symbol: "tablecells", isOnByDefault: true)
    ]
    static func group(_ plugin: PluginDescriptor) -> String { plugin == network ? "Network" : "Previews" }

    static func runtime() async throws -> FeatureRuntime {
        let runtime = FeatureRuntime()
        let log = Log()
        try runtime.set(["studio", "laptop"].map { realm in
            FeatureNode.realm(realm, isolating: [Connection.self, Route.self]) {
                FeatureNode("session") { Provider(offersAtLoad: realm == "studio", log: log, wire: Wire()) }
                FeatureNode("routes") { Router() }
                FeatureNode("page") { Page() }
            }
        })
        await runtime.settled()
        return runtime
    }
}

@MainActor
final class MobilePluginTests: XCTestCase {
    func testGroupsAndDetailsAcrossHosts() async throws {
        let runtime = try await MobilePluginFixture.runtime()
        var choices: [String: PluginHostChoice] = [:]
        let plugin = MobilePluginFixture.network
        let composer = PluginComposer(runtime: runtime, plugins: MobilePluginFixture.catalog,
                                      globalChoice: { _ in true }, setEnabled: { _, _ in },
                                      hostChoice: { _, realm in choices[realm] ?? .inherit },
                                      setHostChoice: { _, realm, choice in choices[realm] = choice })
        let groups = composer.groups(by: MobilePluginFixture.group)
        XCTAssertEqual(groups.map(\.title), ["Previews", "Network"])
        XCTAssertEqual(groups.map { $0.plugins.map(\.id) }, [["notebook", "table"], ["network"]])
        let members = composer.members(of: plugin)
        XCTAssertEqual(members.map(\.id), ["studio/routes", "laptop/routes"])
        XCTAssertEqual(members.map(\.phase), [.active, .pending("Needs Connection from laptop/session")])
        XCTAssertEqual(composer.needs(of: members).map(\.provider), ["studio/session", "laptop/session"])
        XCTAssertEqual(composer.offers(of: members), [
            .init(provider: "studio/routes", service: "Route", consumers: 1),
            .init(provider: "laptop/routes", service: "Route", consumers: 1)
        ])
        XCTAssertEqual(composer.alsoUnloads(with: plugin), ["studio/page", "laptop/page"])
        await composer.setHostChoice(.on, for: plugin, in: "studio")
        XCTAssertEqual(composer.alsoUnloads(with: plugin), ["laptop/page"])
        let filtered = composer.graph.filtered(to: "laptop")
        XCTAssertEqual(filtered.nodes.map(\.id), ["laptop", "laptop/session", "laptop/routes", "laptop/page"])
        XCTAssertEqual(filtered.edges.count, 2)
        await runtime.shutdown()
    }

    func testTwoRealmFramesContainTheirFeaturesWithoutOverlap() async throws {
        let runtime = try await MobilePluginFixture.runtime()
        let layout = FeatureMapLayout(runtime.graph)
        let studio = try XCTUnwrap(layout.containers["studio"])
        let laptop = try XCTUnwrap(layout.containers["laptop"])
        XCTAssertFalse(studio.intersects(laptop))
        for node in runtime.graph.nodes where !node.isContainer {
            let realm = try XCTUnwrap(node.container.flatMap { layout.containers[$0] })
            XCTAssertTrue(realm.contains(try XCTUnwrap(layout.nodes[node.id])))
        }
        await runtime.shutdown()
    }

    func testHostGlobalAndDefaultSources() async {
        let plugin = MobilePluginFixture.network
        var global: Bool?
        var hosts: [String: PluginHostChoice] = [:]
        let composer = PluginComposer(runtime: FeatureRuntime(), plugins: [plugin],
                                      globalChoice: { _ in global }, setEnabled: { _, on in global = on },
                                      hostChoice: { _, realm in hosts[realm] ?? .inherit },
                                      setHostChoice: { _, realm, choice in hosts[realm] = choice == .inherit ? nil : choice })
        func state(_ on: Bool, _ source: PluginEffectiveState.Source) {
            XCTAssertEqual(composer.effectiveState(for: plugin, in: "studio"), .init(isEnabled: on, source: source))
        }
        state(false, .pluginDefault)
        global = false
        state(false, .global)
        await composer.setHostChoice(.on, for: plugin, in: "studio")
        state(true, .host)
        XCTAssertEqual(composer.effectiveState(for: plugin, in: "laptop").source, .global)
        global = true
        await composer.setHostChoice(.off, for: plugin, in: "studio")
        state(false, .host)
        await composer.setHostChoice(.inherit, for: plugin, in: "studio")
        state(true, .global)
        global = nil
        state(false, .pluginDefault)
    }

    func testHostWritesStayInTapOrderAndFailedHostEditReverts() async throws {
        let plugin = MobilePluginFixture.network
        let log = Log()
        var stored = PluginHostChoice.inherit
        let composer = PluginComposer(runtime: FeatureRuntime(), plugins: [plugin], globalChoice: { _ in nil },
                                      setEnabled: { _, _ in }, hostChoice: { _, _ in stored },
                                      setHostChoice: { _, _, choice in
                                          log.events.append(choice.rawValue)
                                          await log.wait("store")
                                          if choice == .off { throw CocoaError(.fileWriteUnknown) }
                                          stored = choice
                                      })
        let first = Task { await composer.setHostChoice(.on, for: plugin, in: "studio") }
        try await until("first host write") { log.events == ["on"] }
        let second = Task { await composer.setHostChoice(.off, for: plugin, in: "studio") }
        try await until("optimistic second choice") { composer.hostChoice(for: plugin, in: "studio") == .off }
        XCTAssertEqual(log.events, ["on"])
        XCTAssertEqual(composer.effectiveState(for: plugin, in: "studio").source, .pluginDefault)
        log.open("store")
        await first.value
        await second.value
        XCTAssertEqual(log.events, ["on", "off"])
        XCTAssertEqual(composer.hostChoice(for: plugin, in: "studio"), .on)
        XCTAssertNotNil(composer.errorMessage)
    }

    func testFailedSwitchRevertsAfterGraphRefresh() async throws {
        let runtime = FeatureRuntime()
        let plugin = MobilePluginFixture.network
        let log = Log()
        let composer = PluginComposer(runtime: runtime, plugins: [plugin], isEnabled: { _ in false },
                                      setEnabled: { _, _ in
                                          await log.wait("write")
                                          throw CocoaError(.fileWriteUnknown)
                                      })
        composer.setEnabled(plugin, true)
        XCTAssertTrue(composer.isEnabled(plugin))
        XCTAssertFalse(composer.effectiveState(for: plugin, in: nil).isEnabled)
        try runtime.set { FeatureNode("session") { Probe(name: "session", log: log) } }
        await runtime.settled()
        XCTAssertTrue(composer.isEnabled(plugin))
        log.open("write")
        try await until("storage failure") { composer.errorMessage != nil }
        XCTAssertFalse(composer.isEnabled(plugin))
        await runtime.shutdown()
    }
}
