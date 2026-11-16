import Combine
import Composition
import Foundation
import XCTest

private enum Relay: ServiceKey { typealias Value = Int }

/// Needs a connection and passes a relay on.
private struct Relayer: Feature {
    @Need(Connection.self) var connection
    @Offer(Relay.self) var relay

    @MainActor func run(_ context: FeatureContext) async throws {
        relay.set(connection.value)
    }
}

private struct RelayUser: Feature {
    @Need(Relay.self) var relay

    @MainActor func run(_ context: FeatureContext) async throws {}
}

@MainActor
final class FeatureGraphTests: XCTestCase {
    func testNodesEdgesAndContainersDescribeTheTree() async throws {
        let log = Log()
        let runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("provider") { Provider(log: log, wire: Wire()) }
            FeatureNode("parent") { Probe(name: "parent", log: log) } children: {
                FeatureNode("child") { Probe(name: "child", log: log) }
            }
            FeatureNode.realm("realm", isolating: [Connection.self]) {
                FeatureNode("provider") { Provider(value: 1, log: log, wire: Wire()) }
                FeatureNode("consumer") { Consumer(name: "inner", log: log, captured: Captured()) }
            }
            FeatureNode("consumer") { Consumer(log: log, captured: Captured()) }
        }
        await runtime.settled()
        let graph = runtime.graph

        XCTAssertEqual(graph.nodes.map(\.id), ["provider", "parent", "parent/child", "realm", "realm/provider",
                                               "realm/consumer", "consumer"])
        XCTAssertEqual(graph.nodes.map(\.name), ["provider", "parent", "child", "realm", "provider", "consumer", "consumer"])
        XCTAssertEqual(graph.nodes.map(\.parent), [nil, nil, "parent", nil, "realm", "realm", nil])
        XCTAssertEqual(graph.nodes.map(\.container), [nil, nil, nil, nil, "realm", "realm", nil])
        XCTAssertEqual(graph.nodes.filter(\.isContainer).map(\.id), ["realm"])
        XCTAssertTrue(graph.nodes.allSatisfy { $0.phase == .active && $0.generation == 1 })
        XCTAssertEqual(graph.nodes.first { $0.id == "realm/provider" }?.offers, ["Connection"])
        XCTAssertEqual(graph.nodes.first { $0.id == "consumer" }?.needs, ["Connection"])
        XCTAssertEqual(graph.edges, [
            FeatureGraph.Edge(service: "Connection", provider: "realm/provider", consumer: "realm/consumer", isSatisfied: true),
            FeatureGraph.Edge(service: "Connection", provider: "provider", consumer: "consumer", isSatisfied: true)
        ])
        XCTAssertEqual(runtime.dependents(of: "realm"), ["realm/provider", "realm/consumer"])
        await runtime.shutdown()
    }

    func testAnUnsatisfiedNeedNamesItsProviderOrNone() async throws {
        let log = Log()
        let runtime = FeatureRuntime()
        let consumer = FeatureNode("consumer") { Consumer(log: log, captured: Captured()) }
        try runtime.set([consumer])
        await runtime.settled()
        XCTAssertEqual(runtime.graph.edges, [
            FeatureGraph.Edge(service: "Connection", provider: nil, consumer: "consumer", isSatisfied: false)
        ])
        XCTAssertEqual(runtime.graph.nodes.first?.phase, .pending("Needs Connection which no feature offers"))

        try runtime.set([consumer, FeatureNode("provider") { Provider(offersAtLoad: false, log: log, wire: Wire()) }])
        await runtime.settled()
        XCTAssertEqual(runtime.graph.edges, [
            FeatureGraph.Edge(service: "Connection", provider: "provider", consumer: "consumer", isSatisfied: false)
        ])
        XCTAssertEqual(runtime.graph.edges.first?.id, "provider>consumer:Connection")
        await runtime.shutdown()
    }

    func testTheGraphFollowsASlotAndIsPublishedOnlyWhenItChanges() async throws {
        let log = Log()
        let wire = Wire()
        let runtime = FeatureRuntime()
        var published: [FeatureGraph] = []
        let subscription = runtime.$graph.dropFirst().sink { published.append($0) }
        let tree = [FeatureNode("provider") { Provider(offersAtLoad: false, log: log, wire: wire) },
                    FeatureNode("consumer") { Consumer(log: log, captured: Captured()) }]
        try runtime.set(tree)
        await runtime.settled()
        XCTAssertEqual(runtime.graph.edges.map(\.isSatisfied), [false])
        try runtime.set(tree)
        await runtime.settled()
        let quiet = published.count

        wire.slot?.set(Counter())
        await runtime.settled()
        XCTAssertEqual(runtime.graph.edges.map(\.isSatisfied), [true])
        XCTAssertEqual(runtime.graph.nodes.last?.phase, .active)
        XCTAssertGreaterThan(published.count, quiet)

        wire.slot?.clear()
        await runtime.settled()
        XCTAssertEqual(runtime.graph.edges.map(\.isSatisfied), [false])
        XCTAssertEqual(runtime.graph.nodes.last?.phase, .pending("Needs Connection from provider"))
        XCTAssertEqual(published.last, runtime.graph)
        for (earlier, later) in zip(published, published.dropFirst()) {
            XCTAssertNotEqual(earlier, later, "An unchanged graph was published again")
        }
        subscription.cancel()
        await runtime.shutdown()
    }

    func testDependentsAreTransitiveAndIncludeChildren() async throws {
        let log = Log()
        let runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("user") { RelayUser() }
            FeatureNode("provider") { Provider(log: log, wire: Wire()) } children: {
                FeatureNode("helper") { Probe(name: "helper", log: log) } children: {
                    FeatureNode("leaf") { Probe(name: "leaf", log: log) }
                }
            }
            FeatureNode("unrelated") { Probe(name: "unrelated", log: log) }
            FeatureNode("relayer") { Relayer() }
        }
        XCTAssertEqual(runtime.dependents(of: "provider"), ["user", "provider/helper", "provider/helper/leaf", "relayer"])
        XCTAssertEqual(runtime.dependents(of: "relayer"), ["user"])
        XCTAssertEqual(runtime.dependents(of: "provider/helper"), ["provider/helper/leaf"])
        XCTAssertEqual(runtime.dependents(of: "unrelated"), [])
        XCTAssertEqual(runtime.dependents(of: "missing"), [])
        await runtime.settled()
        XCTAssertTrue(runtime.statuses.allSatisfy(\.isActive))
        await runtime.shutdown()
    }
}
