import Darwin
import Foundation
import XCTest
@testable import BridgeProtocol

/// Wire v7: one connection per session, verified once, carrying every request.
@MainActor
final class BridgeLifecycleTests: XCTestCase {
    private func endpoint() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("bridge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("viewer.sock")
    }

    private func channel(_ url: URL, closed: BridgeProbe = BridgeProbe(), verified: BridgeProbe = BridgeProbe()) -> BridgeChannel {
        BridgeChannel(socketURL: url, verifyPeer: { _ in verified.mark() }, onClose: { closed.mark($0.sessionFailure, $0.message) })
    }

    private func wait(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testOneConnectionCarriesManyRequestsAndVerifiesEachPeerOnce() async throws {
        let url = try endpoint(), serverChecks = BridgeProbe(), clientChecks = BridgeProbe(), connections = BridgeConnections()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in serverChecks.mark() }) { request, connection in
            await connections.record(connection)
            var response = BridgeResponse(); response.status = request.operation
            return response
        }
        let channel = channel(url, verified: clientChecks)
        for operation in ["catalog", "list", "status"] {
            let response = try await channel.exchange(BridgeRequest(operation))
            XCTAssertEqual(response.status, operation)
        }
        let seen = await connections.ids
        XCTAssertEqual(seen.count, 1, "Every request travelled on the same connection")
        XCTAssertEqual(serverChecks.count, 1)
        XCTAssertEqual(clientChecks.count, 1)
        channel.close()
        await server.close()
    }

    func testASlowCallDoesNotDelayAnotherOnTheSameConnection() async throws {
        let url = try endpoint(), gate = BridgeHandlerGate()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in }) { request, _ in
            if request.operation == "slow" { await gate.wait() }
            var response = BridgeResponse(); response.status = request.operation
            return response
        }
        let channel = channel(url)
        let slow = Task { try await channel.exchange(BridgeRequest("slow")) }
        try await wait("the slow call to start") { await gate.started }
        let fast = try await channel.exchange(BridgeRequest("fast"))
        XCTAssertEqual(fast.status, "fast")
        await gate.release()
        let late = try await slow.value
        XCTAssertEqual(late.status, "slow")
        channel.close()
        await server.close()
    }

    func testStoppingTheServerEndsTheSessionAtOnceAndFailsCallsInFlight() async throws {
        let url = try endpoint(), gate = BridgeHandlerGate(), closed = BridgeProbe()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in }) { _, _ in
            await gate.wait(); return BridgeResponse()
        }
        let channel = channel(url, closed: closed)
        let call = Task { try await channel.exchange(BridgeRequest("list")) }
        try await wait("the call to reach the handler") { await gate.started }
        server.stop()
        // No request is needed to notice: the connection itself reports the end.
        try await wait("the close report") { closed.count == 1 }
        XCTAssertEqual(closed.failure, .unavailable)
        do { _ = try await call.value; XCTFail("A call survived the end of its session") }
        catch { XCTAssertEqual((error as? BridgeError)?.sessionFailure, .unavailable) }
        do { _ = try await channel.exchange(BridgeRequest("catalog")); XCTFail("An ended channel accepted a request") } catch {}
        await gate.release()
        await server.close()
        XCTAssertEqual(closed.count, 1, "The end is reported once")
    }

    func testClientGoingAwayIsReportedAndCancelsItsCalls() async throws {
        let url = try endpoint(), gate = BridgeHandlerGate(), gone = BridgeConnections(), cancelled = BridgeProbe()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in }, onDisconnect: { id in
            Task { await gone.record(id) }
        }) { _, _ in
            await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.mark() }
            return BridgeResponse()
        }
        let channel = channel(url)
        let call = Task { try await channel.exchange(BridgeRequest("fetch")) }
        try await wait("the call to reach the handler") { await gate.started }
        channel.close()
        try await wait("the disconnect report") { await gone.ids.count == 1 }
        try await wait("the handler to be cancelled") { cancelled.count == 1 }
        do { _ = try await call.value; XCTFail("A call survived its channel") } catch {}
        await gate.release()
        await server.close()
    }

    func testANoticeTellsThePeerWhyItsSessionEnded() async throws {
        let url = try endpoint(), closed = BridgeProbe()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in }) { _, _ in BridgeResponse() }
        let first = channel(url, closed: closed)
        _ = try await first.exchange(BridgeRequest("catalog"))
        server.disconnectAll(BridgeResponse(error: "Access was revoked.", sessionFailure: .unauthorized))
        try await wait("the notice") { closed.count == 1 }
        XCTAssertEqual(closed.failure, .unauthorized)
        XCTAssertEqual(closed.message, "Access was revoked.")
        // The endpoint still accepts a new session.
        let second = channel(url)
        _ = try await second.exchange(BridgeRequest("catalog"))
        second.close()
        await server.close()
    }

    func testACancelledCallerStopsWaitingAndItsLateReceiptIsReleased() async throws {
        let url = try endpoint(), gate = BridgeHandlerGate(), operations = BridgeOperations(), job = UUID()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in }) { request, _ in
            await operations.record(request.operation, request.jobID)
            guard request.operation == "fetch" else { return BridgeResponse() }
            await gate.wait()
            var response = BridgeResponse(); response.status = "pending"; response.jobID = job
            return response
        }
        let channel = channel(url)
        let call = Task { try await channel.exchange(BridgeRequest("fetch")) }
        try await wait("the call to reach the handler") { await gate.started }
        call.cancel()
        do { _ = try await call.value; XCTFail("A cancelled call returned") } catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        try await wait("the release of the accepted work") { await operations.released == [job] }
        let still = try await channel.exchange(BridgeRequest("catalog"))
        XCTAssertNil(still.error, "Cancelling one call leaves the session usable")
        channel.close()
        await server.close()
    }

    func testAnOlderPeerIsAnsweredInItsOwnShapeAndANewerClientSeesAnOlderServerAsIncompatible() async throws {
        let url = try endpoint()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in }) { _, _ in
            XCTFail("An older peer's request must not reach the handler"); return BridgeResponse()
        }
        // A v6 peer sends a bare request and reads a bare response.
        let fd = try BridgeSocket.connect(url); defer { Darwin.close(fd) }
        try BridgeSocket.send(BridgeRequest("catalog"), fd: fd)
        let reply = try BridgeSocket.receive(BridgeResponse.self, fd: fd)
        XCTAssertEqual(reply.sessionFailure, .incompatible)
        XCTAssertEqual(reply.error, "Update Frame and RelayBar to compatible versions.")
        await server.close()

        // A v6 server answers every frame with a bare response; the channel reports that as incompatible.
        let old = try endpoint(), closed = BridgeProbe()
        let listener = try LegacyServer(url: old)
        let channel = channel(old, closed: closed)
        do { _ = try await channel.exchange(BridgeRequest("catalog")); XCTFail("An older server was accepted") }
        catch { XCTAssertEqual((error as? BridgeError)?.sessionFailure, .incompatible) }
        XCTAssertEqual(closed.failure, .incompatible)
        listener.stop()
    }

    func testCloseInterruptsIdleConnectionWaitsForRunningHandlerAndAllowsReplacement() async throws {
        let url = try endpoint(), gate = BridgeHandlerGate()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in }) { request, _ in
            if request.operation == "slow" { await gate.wait() }
            return BridgeResponse()
        }
        let idle = channel(url), busy = channel(url)
        _ = try await idle.exchange(BridgeRequest("catalog"))
        let call = Task { try await busy.exchange(BridgeRequest("slow")) }
        try await wait("the slow call to start") { await gate.started }
        var closed = false
        let closing = Task { await server.close(); closed = true }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(closed, "Closing waits for a handler that is already running")
        await gate.release()
        await closing.value
        _ = try? await call.value
        // A still-open listener would reject this as another live RelayBar instance.
        let replacement = try BridgeSocketServer(url: url, verifyPeer: { _ in }) { _, _ in BridgeResponse() }
        await replacement.close()
        await server.close()
    }

    func testConnectingWithNoServerFailsAsUnavailableWithoutReportingAClose() async throws {
        let url = try endpoint(), closed = BridgeProbe()
        let channel = channel(url, closed: closed)
        do { _ = try await channel.exchange(BridgeRequest("catalog")); XCTFail("Connected to nothing") }
        catch { XCTAssertEqual((error as? BridgeError)?.sessionFailure, .unavailable) }
        XCTAssertEqual(closed.count, 0, "A connection that never opened has no session to end")
    }

    func testPeersThatHangUpAtOnceCannotRaiseSIGPIPEAndTheServerKeepsAnswering() async throws {
        // macOS refuses SO_NOSIGPIPE on a socket whose peer has gone, so such a socket must never be written.
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        Darwin.close(pair[1])
        XCTAssertFalse(BridgeSocket.configure(pair[0]))
        Darwin.close(pair[0])

        // Each peer is refused, so the server writes to it; these hang up before that write.
        let url = try endpoint()
        let server = try BridgeSocketServer(url: url, verifyPeer: { _ in throw BridgeError("Not Frame.") }) { _, _ in
            BridgeResponse()
        }
        for _ in 0..<50 { Darwin.close(try BridgeSocket.connect(url)) }
        let fd = try BridgeSocket.connect(url)
        defer { Darwin.close(fd) }
        let notice = try BridgeSocket.receive(BridgeReply.self, fd: fd)
        XCTAssertEqual(notice.response.error, "Not Frame.", "The process survived and a waiting peer is still told why")
        await server.close()
    }
}

private final class BridgeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marks = 0
    private var lastFailure: BridgeSessionFailure?
    private var lastMessage: String?
    var count: Int { lock.withLock { marks } }
    var failure: BridgeSessionFailure? { lock.withLock { lastFailure } }
    var message: String? { lock.withLock { lastMessage } }
    func mark(_ failure: BridgeSessionFailure? = nil, _ message: String? = nil) {
        lock.withLock { marks += 1; lastFailure = failure; lastMessage = message }
    }
}

private actor BridgeConnections {
    private(set) var ids: Set<UUID> = []
    func record(_ id: UUID) { ids.insert(id) }
}

private actor BridgeOperations {
    private(set) var released: [UUID] = []
    func record(_ operation: String, _ job: UUID?) { if operation == "release", let job { released.append(job) } }
}

private actor BridgeHandlerGate {
    private(set) var started = false
    private var open = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        started = true
        if !open { await withCheckedContinuation { continuations.append($0) } }
    }
    func release() {
        open = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

/// A minimal stand-in for a v6 endpoint: one bare response per connection.
private final class LegacyServer: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        var address = try BridgeSocket.address(url)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { throw BridgeError("legacy listener failed") }
        let listener = descriptor
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = try? BridgeSocket.receiveFrame(fd: fd)
            var response = BridgeResponse(error: "The data couldn’t be read because it is missing.")
            response.version = 6
            try? BridgeSocket.send(response, fd: fd)
            Darwin.close(fd)
        }
    }
    func stop() { Darwin.close(descriptor) }
}
