import Composition
import Foundation
import XCTest

/// Shared recorder for test features. Gates let a test hold a load or a cleanup open without timing.
@MainActor
final class Log {
    var events: [String] = []
    var counts: [String: Int] = [:]
    private var opened: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func count(_ name: String) -> Int { counts[name, default: 0] }
    func wait(_ gate: String) async {
        if opened.contains(gate) { return }
        await withCheckedContinuation { waiting[gate, default: []].append($0) }
    }
    func open(_ gate: String) {
        opened.insert(gate)
        for continuation in waiting.removeValue(forKey: gate) ?? [] { continuation.resume() }
    }
}

@MainActor
func until(_ what: String, timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
           _ condition: () -> Bool) async throws {
    let start = ContinuousClock.now
    while !condition() {
        if start.duration(to: .now) > timeout {
            XCTFail("Timed out waiting for \(what)", file: file, line: line)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// Records its load and cleanup, optionally waiting at a named gate in either.
struct Probe: Feature {
    let name: String
    var loadGate: String?
    var cleanupGate: String?
    var revision = 0
    @Constant var log: Log

    @MainActor func run(_ context: FeatureContext) async throws {
        log.counts[name, default: 0] += 1
        log.events.append("loading \(name)")
        if let loadGate { await log.wait(loadGate) }
        let log = log, name = name, cleanupGate = cleanupGate
        try context.effect("\(name) cleanup") {
            log.events.append("unloading \(name)")
            if let cleanupGate { await log.wait(cleanupGate) }
            log.events.append("unloaded \(name)")
        }
        log.events.append("loaded \(name)")
    }
}

final class Counter { var value = 0 }
enum Connection: ServiceKey { typealias Value = Counter }

/// Offers a connection. The test keeps the slot to drive availability by hand.
@MainActor
final class Wire { var slot: Slot<Counter>? }

struct Provider: Feature {
    var value = 0
    var offersAtLoad = true
    @Constant var log: Log
    @Constant var wire: Wire
    @Offer(Connection.self) var connection

    @MainActor func run(_ context: FeatureContext) async throws {
        log.counts["provider", default: 0] += 1
        wire.slot = connection
        if offersAtLoad {
            let counter = Counter()
            counter.value = value
            connection.set(counter)
        }
        let log = log
        try context.effect("provider cleanup") { log.events.append("unloaded provider") }
    }
}

@MainActor
final class Captured { var context: FeatureContext?; var counter: Counter? }

struct Consumer: Feature {
    var name = "consumer"
    @Constant var log: Log
    @Constant var captured: Captured
    @Need(Connection.self) var connection

    @MainActor func run(_ context: FeatureContext) async throws {
        log.counts[name, default: 0] += 1
        captured.context = context
        captured.counter = connection
        let log = log, name = name, connection = connection
        try context.effect("\(name) cleanup") {
            // A consumer's cleanup still sees the service it loaded against.
            log.events.append("unloaded \(name) with \(connection.value)")
        }
    }
}
