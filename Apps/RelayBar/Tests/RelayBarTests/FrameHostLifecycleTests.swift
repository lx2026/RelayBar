import BridgeProtocol
import Foundation
import XCTest
@testable import RelayBar

@MainActor
final class FrameHostLifecycleTests: XCTestCase {
    func testShutdownWithdrawsAuthorityAndWaitsForLateOperation() async throws {
        let suite = "FrameHostLifecycle.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let catalog = RemoteServerCatalog(defaults: defaults)
        _ = try catalog.add(name: "Fixture", sshHost: "fixture.invalid")
        let service = WaitingBridgeService()
        var available = true
        let broker = FrameBridgeBroker(catalog: catalog, defaults: defaults, available: { available }, makeService: { service })
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        var request = BridgeRequest("list"); request.sourceID = source.id; request.path = "/fixture"
        let job = try XCTUnwrap(broker.handle(request).jobID)
        for _ in 0..<100 {
            if await service.started { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = await service.started; XCTAssertTrue(started)
        available = false
        XCTAssertNotNil(broker.handle(BridgeRequest("catalog")).error, "Withdrawal must precede asynchronous disposal")
        var finished = false
        let shutdown = Task { await broker.shutdown(); finished = true }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(finished)
        XCTAssertNotNil(broker.handle(BridgeRequest("catalog")).error)
        await service.finish()
        await shutdown.value
        XCTAssertTrue(finished)
        var status = BridgeRequest("status"); status.jobID = job
        XCTAssertNotNil(broker.handle(status).error)
        await broker.shutdown()
    }

    private func broker(_ service: any RemoteFileServing) throws -> (FrameBridgeBroker, BridgeSource, UserDefaults, String) {
        let suite = "FrameHostSession.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let catalog = RemoteServerCatalog(defaults: defaults)
        _ = try catalog.add(name: "Fixture", sshHost: "fixture.invalid")
        let broker = FrameBridgeBroker(catalog: catalog, defaults: defaults, makeService: { service })
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        return (broker, source, defaults, suite)
    }

    func testStatusIsAnsweredWhenTheJobFinishesNotOnATimer() async throws {
        let service = WaitingBridgeService()
        let (broker, source, defaults, suite) = try broker(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = UUID()
        var request = BridgeRequest("list"); request.sourceID = source.id; request.path = "/fixture"
        let job = try XCTUnwrap(broker.handle(request, connection: connection).jobID)
        var status = BridgeRequest("status"); status.jobID = job
        let start = ContinuousClock.now
        let waiting = Task { await broker.respond(status, connection: connection) }
        for _ in 0..<100 {
            if await service.started { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try await Task.sleep(for: .milliseconds(40))
        await service.finish()
        let response = await waiting.value
        XCTAssertEqual(response.status, "ready", "The held status request is answered by the job finishing")
        XCTAssertNotNil(response.listingID)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(400), "It did not wait out the progress interval")
        await broker.shutdown()
    }

    func testAConnectionEndingStopsItsJobsAndLeavesAnotherSessionsWork() async throws {
        let service = CountingBridgeService()
        let (broker, source, defaults, suite) = try broker(service)
        defer { defaults.removePersistentDomain(forName: suite) }
        let gone = UUID(), staying = UUID()
        var request = BridgeRequest("list"); request.sourceID = source.id; request.path = "/fixture"
        let lost = try XCTUnwrap(broker.handle(request, connection: gone).jobID)
        let kept = try XCTUnwrap(broker.handle(request, connection: staying).jobID)
        for _ in 0..<200 {
            if await service.started == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        broker.disconnected(gone)
        for _ in 0..<200 {
            if await service.cancelled == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let cancelled = await service.cancelled
        XCTAssertEqual(cancelled, 1, "The lost session's transfer is cancelled at once, not after an expiry interval")
        var status = BridgeRequest("status"); status.jobID = lost
        XCTAssertNotNil(broker.handle(status, connection: gone).error)
        status.jobID = kept
        XCTAssertEqual(broker.handle(status, connection: staying).status, "pending")
        await broker.shutdown()
    }
}

/// Holds every listing until cancelled, and counts both.
private actor CountingBridgeService: RemoteFileServing {
    private(set) var started = 0
    private(set) var cancelled = 0
    func frameAsset(server: RemoteServer, input: BridgeAssetInput) async throws -> BridgeAssetResult {
        started += 1
        do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1; throw error }
        return BridgeAssetResult()
    }
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] { [] }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {}
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL { throw CancellationError() }
}

private actor WaitingBridgeService: RemoteFileServing {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func frameAsset(server: RemoteServer, input: BridgeAssetInput) async throws -> BridgeAssetResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        var result = BridgeAssetResult(); result.entries = []; return result
    }
    func finish() { continuation?.resume(); continuation = nil }
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] { [] }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {}
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL { throw CancellationError() }
}
