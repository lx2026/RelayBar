import CompositionFixtures
import Composition
import Foundation
import PreviewSupport
import XCTest

@MainActor
final class PreviewRegistryTests: XCTestCase {
    private typealias Registry = FilePreviewRegistry<String, String>
    private enum Previews: ServiceKey { typealias Value = Registry }

    private struct Host: Feature {
        @Constant var registry: Registry
        @Offer(Previews.self) var previews
        @MainActor func run(_ context: FeatureContext) async throws { previews.set(registry) }
    }

    /// One preview format. Its limit is configuration, so a new limit reloads only this feature.
    private struct Format: Feature {
        let id: String
        let ext: String
        var limit: Int64 = 10
        var gate: String?
        @Constant var log: Log
        @Need(Previews.self) var previews

        @MainActor func run(_ context: FeatureContext) async throws {
            let log = log, id = id, gate = gate
            try previews.register(.init(id: id, title: id, extensions: [ext], maximumBytes: limit), in: context) { input in
                log.events.append("render \(id)")
                if let gate { await log.wait(gate) }
                return PreviewResource(input, stop: { log.events.append("stop \(id)") }, dispose: {
                    if let gate { await log.wait(gate + ".dispose") }
                    log.events.append("dispose \(id)")
                })
            }
        }
    }

    func testRemovingAFormatClosesItsResultsAndLeavesOtherFormatsActive() async throws {
        let registry = Registry(), log = Log(), runtime = FeatureRuntime()
        func tree(html: Bool, imageLimit: Int64 = 20) -> [FeatureNode] {
            var nodes = [FeatureNode("previews") { Host(registry: registry) },
                         FeatureNode("image") { Format(id: "image", ext: "png", limit: imageLimit, log: log) }]
            if html { nodes.append(FeatureNode("html") { Format(id: "html", ext: "html", log: log) }) }
            return nodes
        }
        try runtime.set(tree(html: true))
        await runtime.settled()
        let html = try await registry.open(filename: "test.html", bytes: 9, request: "html")
        let image = try await registry.open(filename: "test.png", bytes: 19, request: "image")
        var closed = false
        html.onClose = { closed = true }

        try runtime.set(tree(html: false))
        await runtime.settled()
        XCTAssertTrue(closed); XCTAssertTrue(html.isClosed); XCTAssertFalse(image.isClosed)
        XCTAssertTrue(log.events.contains("dispose html")); XCTAssertFalse(log.events.contains("dispose image"))
        XCTAssertNil(registry.descriptor(for: "test.html"))
        do { _ = try await registry.open(filename: "large.png", bytes: 21, request: "large"); XCTFail("Limit ignored") } catch {}

        // A lower limit is a configuration change: only that format reloads, and its results close.
        try runtime.set(tree(html: false, imageLimit: 5))
        await runtime.settled()
        XCTAssertTrue(image.isClosed)
        XCTAssertEqual(registry.descriptor(for: "x.png")?.maximumBytes, 5)
        XCTAssertEqual(runtime.status("previews")?.generation, 1)
        await runtime.shutdown()
        XCTAssertTrue(registry.descriptors.isEmpty)
    }

    func testWithdrawalRemovesTheFormatAtOnceAndWaitsForALateRender() async throws {
        let registry = Registry(), log = Log(), runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("previews") { Host(registry: registry) }
            FeatureNode("slow") { Format(id: "fixture", ext: "test", gate: "render", log: log) }
        }
        await runtime.settled()
        let opening = Task { try await registry.open(filename: "file.test", bytes: 1, request: "late") }
        try await until("the render to start") { log.events.contains("render fixture") }
        try runtime.set { FeatureNode("previews") { Host(registry: registry) } }
        try await until("the format to disappear") { registry.descriptor(for: "file.test") == nil }
        XCTAssertEqual(runtime.status("slow")?.phase, .unloading)
        log.open("render"); log.open("render.dispose")
        await runtime.settled()
        XCTAssertTrue(log.events.contains("dispose fixture"))
        do { _ = try await opening.value; XCTFail("A late result escaped") } catch {}
        await runtime.shutdown()
    }

    func testUnloadJoinsACleanupThatWasAlreadyRunning() async throws {
        let registry = Registry(), log = Log(), runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("previews") { Host(registry: registry) }
            FeatureNode("format") { Format(id: "fixture", ext: "test", gate: "hold", log: log) }
        }
        await runtime.settled()
        log.open("hold")
        let session = try await registry.open(kind: "fixture", bytes: 1, request: "content")
        session.invalidate()
        XCTAssertEqual(log.events.filter { $0 == "stop fixture" }.count, 1)
        let closing = Task { await session.close() }
        try runtime.set([])
        try await until("the format to disappear") { registry.descriptors.isEmpty }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNotNil(runtime.status("format"), "Unload must wait for the cleanup already in flight")
        log.open("hold.dispose")
        await runtime.settled(); await closing.value
        XCTAssertEqual(log.events.filter { $0 == "stop fixture" }.count, 1)
        XCTAssertEqual(log.events.filter { $0 == "dispose fixture" }.count, 1)
    }

    func testAFeatureFromAnotherModuleJoinsAndLeavesWithOnlyANode() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        let name = "probe-\(UUID().uuidString)", log = Log(), runtime = FeatureRuntime()
        func tree(probe: Bool) -> [FeatureNode] {
            var nodes = [FeatureNode("core") { Probe(name: "core", log: log) }]
            if probe { nodes.append(FeatureNode("fixture") { FileProbe(file: file, notification: name) }) }
            return nodes
        }
        func contents() -> String? { try? String(contentsOf: file, encoding: .utf8) }

        try runtime.set(tree(probe: true)); await runtime.settled()
        XCTAssertEqual(contents(), "active")
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
        XCTAssertEqual(contents(), "observed")

        try runtime.set(tree(probe: false)); await runtime.settled()
        XCTAssertNil(contents())
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
        XCTAssertNil(contents(), "A removed feature must not react")

        try runtime.set(tree(probe: true)); await runtime.settled()
        XCTAssertEqual(contents(), "active")
        XCTAssertEqual(log.count("core"), 1, "The unrelated feature keeps its instance")
        await runtime.shutdown()
        XCTAssertNil(contents())
    }
}
