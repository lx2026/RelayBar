#if os(macOS)
import Foundation
import NIOCore
import NIOPosix
import os
import RelayTransport
@testable import RelayWebRoutes
import Testing

private func client<R: Sendable>(_ port: UInt16, host: String = "127.0.0.1",
                                 _ body: @escaping @Sendable (Peer) async throws -> R) async throws -> R {
    let socket = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .connect(host: host, port: Int(port)) { channel in
            channel.eventLoop.makeCompletedFuture {
                try Socket(wrappingChannelSynchronously: channel, configuration: .init(isOutboundHalfClosureEnabled: true))
            }
        }
    return try await socket.executeThenClose { input, output in
        let peer = Peer(channel: socket.channel, input: SocketReader(input), output: output)
        let timer = peer.timeout(.seconds(5))
        defer { timer.cancel() }
        return try await body(peer)
    }
}

private final class TestCursor: @unchecked Sendable {
    var iterator: AsyncStream<Data>.Iterator
    init(_ input: AsyncStream<Data>) { iterator = input.makeAsyncIterator() }
    func next() async -> Data? { await iterator.next() }
}

private final class TestOpener: RouteStreamOpener {
    struct State {
        var reconnect = false
        var enters = 0
        var hosts = [String]()
        var writes = Data()
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var isReconnecting: Bool { state.withLock { $0.reconnect } }
    let name: String
    let failure: TransportError?
    let openDelay: Duration
    init(_ name: String = "one", failure: TransportError? = nil, openDelay: Duration = .zero) {
        self.openDelay = openDelay
        self.name = name
        self.failure = failure
    }

    func withRouteStream<R: Sendable>(host: String, port: UInt16,
                         _ body: @escaping @Sendable (RouteStream) async throws -> R) async throws -> R {
        state.withLock { $0.enters += 1; $0.hosts.append(host) }
        if openDelay > .zero { try await Task.sleep(for: openDelay) }
        if let failure { throw failure }
        let (input, sender) = AsyncStream<Data>.makeStream()
        let cursor = TestCursor(input)
        defer { sender.finish() }
        return try await body(RouteStream(receive: { await cursor.next() }, write: { bytes in
            self.state.withLock { $0.writes.append(bytes) }
            let text = String(decoding: bytes, as: UTF8.self)
            if text.hasPrefix("GET ") && text.lowercased().contains("upgrade: websocket") {
                let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
                sender.yield(Data(response.utf8) + Data([0x81, 5]) + Data("hello".utf8))
            } else if bytes == Data([0x82, 0x82, 1, 2, 3, 4, 1, 0xfd]) {
                sender.yield(Data([0x82, 2, 0, 0xff]))
            } else if text.hasPrefix("GET ") {
                sender.yield(Data("HTTP/1.1 200 OK\r\nContent-Length: \(self.name.utf8.count)\r\n\r\n\(self.name)".utf8))
            } else { sender.yield(bytes) }
        }, finishWriting: { sender.finish() }))
    }
}

private func authenticate(_ peer: Peer, _ proxy: SOCKSProxy) async throws {
    try await peer.send(Data([5, 2, 0, 2]))
    #expect(try await peer.input.read(2) == [5, 2])
    let user = Array(proxy.username.utf8), password = Array(proxy.password.utf8)
    try await peer.send(Data([1, UInt8(user.count)] + user + [UInt8(password.count)] + password))
    #expect(try await peer.input.read(2) == [1, 0])
}

private func connect(_ peer: Peer, port: UInt16, name: String = "test.localhost",
                     address: [UInt8]? = nil, command: UInt8 = 1) async throws -> UInt8 {
    let destination: [UInt8] = address ?? ([3, UInt8(name.utf8.count)] + Array(name.utf8))
    try await peer.send(Data([5, command, 0] + destination + [UInt8(port >> 8), UInt8(truncatingIfNeeded: port)]))
    return try await peer.input.read(10)[1]
}

@Test func proxyAuthenticationAndPolicy() async throws {
    let opener = TestOpener()
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: opener)
    proxy.setDestinations([.init(host: "test.localhost", port: 80), .init(host: "::1", port: 80),
                           .init(host: "127.0.0.1", port: 80)])
    try await client(proxy.port) { peer in
        try await peer.send(Data([5, 1, 0]))
        #expect(try await peer.input.read(2) == [5, 255])
    }
    let user = Array(proxy.username.utf8)
    let wrongPassword: [UInt8] = [1, UInt8(user.count)] + user + [1, 98]
    for credentials: [UInt8] in [[1, 0, 0], [1, 1, 97, 1, 98], wrongPassword] {
        try await client(proxy.port) { peer in
            try await peer.send(Data([5, 1, 2] + credentials))
            #expect(try await peer.input.read(4) == [5, 2, 1, 1])
        }
    }
    try await client(proxy.port) { peer in
        try await authenticate(peer, proxy)
        #expect(try await connect(peer, port: 81) == 2)
    }
    try await client(proxy.port) { peer in
        try await authenticate(peer, proxy)
        #expect(try await connect(peer, port: 80, command: 2) == 7)
    }
    for address: [UInt8] in [[1, 127, 0, 0, 1], [4] + Array(repeating: 0, count: 15) + [1]] {
        try await client(proxy.port) { peer in
            try await authenticate(peer, proxy)
            #expect(try await connect(peer, port: 80, address: address) == 0)
            try await peer.send(Data([42]))
            peer.output.finish()
            #expect(try await peer.input.read(1) == [42])
            #expect(try await peer.input.next() == nil)
        }
    }
    #expect(opener.state.withLock { $0.hosts } == ["127.0.0.1", "::1"])
    await proxy.stop()
}

@Test func proxyThroughOpenSSH() async throws {
    let sshd = try OpenSSHFixture()
    defer { sshd.cleanup() }
    try await sshd.start()
    let session = SSHSession(sshd.configuration())
    try await session.resume()
    let http = Listeners()
    let port = try await http.bind(port: 0, dual: false, capacity: 1) { peer in
        do {
            let request = try await peer.input.through([13, 10, 13, 10], limit: 200)
            #expect(String(decoding: request, as: UTF8.self) == "GET / HTTP/1.0\r\n\r\n")
            #expect(try await peer.input.next() == nil)
            try await peer.send(Data("HTTP/1.0 200 OK\r\n\r\npassed".utf8))
        } catch { Issue.record("HTTP fixture failed") }
    }
    let closed = try loopbackPort()
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: session)
    proxy.setDestinations([.init(host: "test.localhost", port: port), .init(host: "test.localhost", port: closed)])
    try await client(proxy.port) { peer in
        try await authenticate(peer, proxy)
        #expect(try await connect(peer, port: port) == 0)
        try await peer.send(Data("GET / HTTP/1.0\r\n\r\n".utf8))
        peer.output.finish()
        var reply = Data()
        while let part = try await peer.input.next() { reply.append(part) }
        #expect(String(decoding: reply, as: UTF8.self) == "HTTP/1.0 200 OK\r\n\r\npassed")
    }
    try await client(proxy.port) { peer in
        try await authenticate(peer, proxy)
        #expect(try await connect(peer, port: closed) == 5)
    }
    await proxy.stop()
    await http.stop()
    await session.suspend()
}

private func request(_ host: String, _ fields: [String]) -> Data {
    Data((["GET / HTTP/1.1", "Host: " + host] + fields + ["", ""]).joined(separator: "\r\n").utf8)
}

private func response(_ peer: Peer) async throws -> (Int, String) {
    let bytes = try await peer.input.through([13, 10, 13, 10], limit: 4096)
    let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
    let status = try #require(Int(lines[0].split(separator: " ")[1]))
    let length = lines.first { $0.lowercased().hasPrefix("content-length: ") }.flatMap { Int($0.dropFirst(16)) } ?? 0
    return (status, String(decoding: try await peer.input.read(length), as: UTF8.self))
}

@Test func gateAuthorizationAndProfileIsolation() async throws {
    let gate = try await LocalhostGate.start(port: 0)
    let opener = TestOpener(), other = TestOpener("two")
    let host = "localhost:\(gate.port)", origin = "http://\(host)"
    let one = gate.registry.register(profile: UUID(), privateName: "one.localhost", ports: [gate.port], origins: [origin], opener: opener)
    let two = gate.registry.register(profile: UUID(), privateName: "two.localhost", ports: [gate.port], origins: [origin], opener: other)
    let ua = "User-Agent: Browser " + one.userAgentComponent
    let cookie = "Cookie: app=keep; __relay=app; __relay_0=foreign; \(GateToken.cookieName(for: gate.port))=" + one.value
    let nav = ["Sec-Fetch-Site: cross-site", "Sec-Fetch-Mode: navigate", "Sec-Fetch-Dest: document"]
    for fields in [[ua, cookie, "Origin: " + origin], [cookie, "Origin: http://one.localhost:8080"],
                   [ua, "Sec-Fetch-Site: same-origin"], [ua] + nav] {
        try await client(gate.port) { peer in
            try await peer.send(request(host, fields))
            #expect(try await response(peer).1 == "one")
        }
    }
    for host in ["127.0.0.1:\(gate.port)", "[::1]:\(gate.port)"] {
        try await client(gate.port, host: "::1") { peer in
            try await peer.send(request(host, [ua]))
            #expect(try await response(peer).0 == 200)
        }
    }
    let clean = opener.state.withLock { String(decoding: $0.writes, as: UTF8.self) }
    let leaked = clean.contains(one.value)
    #expect(!leaked)
    let preserved = clean.contains("User-Agent: Browser\r\n") && clean.contains("Cookie: app=keep; __relay=app\r\n")
    #expect(preserved)
    for dest in ["iframe", "frame", "embed", "object", ""] {
        try await client(gate.port) { peer in
            try await peer.send(request(host, [ua] + nav.dropLast() + (dest.isEmpty ? [] : ["Sec-Fetch-Dest: " + dest])))
            #expect(try await response(peer).0 == 403)
        }
    }
    for fields in [[], nav, ["Cookie: __relay_0=" + one.value], [ua, "Origin: https://foreign.test"], [ua, "Origin: http://localhost:1"],
                   [ua, "Origin: http://two.localhost"], [ua, "Sec-Fetch-Site: cross-site", "Sec-Fetch-Mode: cors"],
                   [ua, "Sec-Fetch-Site: cross-site "], ["Cookie: __relay=invalid"], [ua, "Host: \(host)"]] {
        try await client(gate.port) { peer in
            try await peer.send(request(host, fields))
            #expect(try await response(peer).0 == 403)
        }
    }
    for bad in ["localhost:1", "foreign.test:\(gate.port)"] {
        try await client(gate.port) { peer in
            try await peer.send(request(bad, [ua]))
            #expect(try await response(peer).0 == 403)
        }
    }
    let second = "User-Agent: " + two.userAgentComponent
    try await client(gate.port) { peer in
        try await peer.send(request(host, [second]))
        #expect(try await response(peer).1 == "two")
        try await peer.send(request(host, [ua]))
        #expect(try await response(peer).0 == 403)
        #expect(try await peer.input.next() == nil)
    }
    try await client(gate.port) { peer in
        try await peer.send(request(host, [ua]) + request(host, []))
        #expect(try await response(peer).0 == 200)
        #expect(try await response(peer).0 == 403)
    }
    await gate.stop()
}

@Test func gateUpgradeAndRevocation() async throws {
    let gate = try await LocalhostGate.start(port: 0)
    let opener = TestOpener()
    for upgrade in [false, true] {
        let token = gate.registry.register(profile: UUID(), privateName: "one.localhost", ports: [gate.port], origins: [], opener: opener)
        let ua = "User-Agent: " + token.userAgentComponent
        let fields = [ua] + (upgrade ? ["Connection: upgrade", "Upgrade: websocket",
                                      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13"] : [])
        try await client(gate.port) { peer in
            try await peer.send(request("localhost:\(gate.port)", fields))
            let result = try await response(peer)
            #expect(result.0 == (upgrade ? 101 : 200))
            if upgrade {
                #expect(try await peer.input.read(7) == [0x81, 5] + Array("hello".utf8))
                try await peer.send(Data([0x82, 0x82, 1, 2, 3, 4, 1, 0xfd]))
                #expect(try await peer.input.read(4) == [0x82, 2, 0, 255])
            }
            await gate.registry.revoke(token)
            #expect(try await peer.input.next() == nil)
        }
        try await client(gate.port) { peer in
            try await peer.send(request("localhost:\(gate.port)", [ua]))
            #expect(try await response(peer).0 == 403)
        }
    }
    await gate.stop()
}

@Test func gateRefusalsAndSilenceLimits() async throws {
    var limits = GateLimits()
    limits.headBytes = 512
    limits.headTimeout = .milliseconds(500)
    limits.unvalidatedSockets = 2
    let gate = try await LocalhostGate.start(port: 0, limits: limits)
    let closed = TestOpener(failure: .connectionRefused)
    let token = gate.registry.register(profile: UUID(), privateName: "one.localhost", ports: [gate.port], origins: [], opener: closed)
    let valid = request("localhost:\(gate.port)", ["User-Agent: " + token.userAgentComponent])
    try await client(gate.port) { silent in
        try await Task.sleep(for: .milliseconds(100))
        try await client(gate.port) { newer in
            try await Task.sleep(for: .milliseconds(50))
            try await client(gate.port) { extra in
                try await extra.send(valid)
                #expect(try await response(extra).0 == 502)
            }
            #expect(try await silent.input.next() == nil)
            try await newer.send(valid)
            #expect(try await response(newer).0 == 502)
        }
        }
    try await client(gate.port) { peer in
        let start = ContinuousClock.now
        let eof = try await peer.input.next()
        #expect(eof == nil)
        #expect(start.duration(to: .now) >= .milliseconds(380))
    }
    try await client(gate.port) { peer in
        try await Task.sleep(for: .milliseconds(100))
        try await peer.send(valid)
        let reply = try await response(peer)
        #expect(reply.0 == 502)
        #expect(reply.1.contains("refused"))
    }
    try await client(gate.port) { peer in
        try await peer.send(Data(repeating: 120, count: 513))
        #expect(try await response(peer).0 == 403)
    }
    await gate.stop()
}

@Test func gateRollsBackBothAddressFamilies() async throws {
    for held in ["127.0.0.1", "::1"] {
        let free = held == "::1" ? "127.0.0.1" : "::1"
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        for attempt in 1...16 {
            let busy = try await bootstrap.bind(host: held, port: 0).get()
            defer { busy.close(promise: nil) }
            let port = try #require(busy.localAddress?.port)

            // Retry collisions only during setup. A failed proof after the gate
            // tries to bind must still fail the test.
            let reservation: Channel
            do { reservation = try await bootstrap.bind(host: free, port: port).get() }
            catch let error as IOError where error.errnoCode == EADDRINUSE && attempt < 16 { continue }
            try await reservation.close()
            await #expect(throws: (any Error).self) { try await LocalhostGate.start(port: UInt16(port)) }
            let proof = try await bootstrap.bind(host: free, port: port).get()
            try await proof.close()
            break
        }
    }
}

@Test func proxyBoundsHandshakesAndStreams() async throws {
    var limits = ProxyLimits()
    limits.streams = 1
    limits.handshake = .milliseconds(400)
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: TestOpener(), limits: limits)
    try await client(proxy.port) { first in
        try await first.send(Data([5, 1, 2]))
        #expect(try await first.input.read(2) == [5, 2])
        let start = ContinuousClock.now
        try await client(proxy.port) { second in
            let eof = try await second.input.next()
            #expect(eof == nil)
        }
        #expect(try await first.input.next() == nil)
        #expect(start.duration(to: .now) >= .milliseconds(250))
    }
    await proxy.stop()
}

@Test func proxyBoundsPendingAndHoldsReconnect() async throws {
    let opener = TestOpener()
    var limits = ProxyLimits()
    limits.pendingOpens = 1
    limits.reconnectHold = .milliseconds(800)
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: opener, limits: limits)
    proxy.setDestinations([.init(host: "test.localhost", port: 80)])
    opener.state.withLock { $0.reconnect = true }
    try await client(proxy.port) { first in
        try await authenticate(first, proxy)
        async let held = connect(first, port: 80)
        try await Task.sleep(for: .milliseconds(100))
        #expect(opener.state.withLock { $0.enters } == 0)
        try await client(proxy.port) { second in
            try await authenticate(second, proxy)
            async let queued = connect(second, port: 80)
            try await Task.sleep(for: .milliseconds(100))
            opener.state.withLock { $0.reconnect = false }
            let result = try await queued
            #expect(result == 0)
        }
        opener.state.withLock { $0.reconnect = false }
        let result = try await held
        #expect(result == 0)
    }
    opener.state.withLock { $0.reconnect = true }
    try await client(proxy.port) { first in
        try await authenticate(first, proxy)
        let start = ContinuousClock.now
        #expect(try await connect(first, port: 80) == 4)
        #expect(start.duration(to: .now) >= .milliseconds(700))
    }
    await proxy.stop()
}

@Test func gateSharesGrantsOnlyOnRegisteredPorts() async throws {
    let registry = GateRegistry(), profile = UUID(), opener = TestOpener()
    let a = try await LocalhostGate.start(port: 0, registry: registry)
    let b = try await LocalhostGate.start(port: 0, registry: registry)
    let origin = "http://[::1]:\(a.port)"
    let onlyA = registry.register(profile: profile, privateName: "p.localhost", ports: [a.port],
                                  origins: [origin], opener: opener)
    let both = registry.register(profile: profile, privateName: "p.localhost", ports: [a.port, b.port],
                                 origins: [], opener: opener)
    try await client(b.port) { peer in
        try await peer.send(request("localhost:\(b.port)", ["User-Agent: " + onlyA.userAgentComponent]))
        #expect(try await response(peer).0 == 403)
    }
    let fields = ["User-Agent: " + both.userAgentComponent, "Origin: " + origin]
    try await client(a.port) { first in
        try await first.send(request("localhost:\(a.port)", fields))
        #expect(try await response(first).0 == 200)
        try await client(b.port) { second in
            try await second.send(request("localhost:\(b.port)", fields))
            #expect(try await response(second).0 == 200)
            await registry.revoke(both)
            #expect(try await second.input.next() == nil)
        }
        #expect(try await first.input.next() == nil)
    }
    await a.stop()
    await b.stop()
}

private struct UploadService: RouteStreamOpener {
    let recorded = OSAllocatedUnfairLock(initialState: Data())
    var isReconnecting: Bool { false }
    func withRouteStream<R: Sendable>(host: String, port: UInt16,
        _ body: @escaping @Sendable (RouteStream) async throws -> R) async throws -> R {
        let (input, sender) = AsyncStream<Data>.makeStream()
        let cursor = TestCursor(input)
        defer { sender.finish() }
        return try await body(RouteStream(receive: { await cursor.next() }, write: { bytes in
            recorded.withLock { $0.append(bytes) }
        }, finishWriting: {
            sender.yield(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8))
            sender.finish()
        }))
    }
}

@Test func gateUploadFramingKeepsNextRequestBehindAuthorization() async throws {
    let gate = try await LocalhostGate.start(port: 0)
    let upload = UploadService()
    let token = gate.registry.register(profile: UUID(), privateName: "p.localhost", ports: [gate.port],
                                       origins: [], opener: upload)
    let host = "localhost:\(gate.port)"
    for (frame, payload) in [("Content-Length: 4", "body"),
                             ("Transfer-Encoding: chunked", "4\r\nbody\r\n0\r\nCookie: __relay=private\r\n\r\n")] {
        try await client(gate.port) { peer in
            let post = "POST / HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: \(token.userAgentComponent)\r\n\(frame)\r\n\r\n\(payload)"
            try await peer.send(Data(post.utf8) + request(host, []))
            #expect(try await response(peer).1 == "OK")
            #expect(try await response(peer).0 == 403)
        }
    }
    let writes = upload.recorded.withLock { String(decoding: $0, as: UTF8.self) }
    let clean = !writes.contains(token.value) && !writes.contains("private") && !writes.contains("GET /")
    #expect(clean)
    #expect(writes.contains("\r\n\r\nbody"))
    #expect(writes.hasSuffix("\r\n\r\n4\r\nbody\r\n0\r\n\r\n"))
    await gate.stop()
}

private struct HalfClosedUpstream: RouteStreamOpener {
    let received = OSAllocatedUnfairLock(initialState: Data())
    var isReconnecting: Bool { false }
    func withRouteStream<R: Sendable>(host: String, port: UInt16,
        _ body: @escaping @Sendable (RouteStream) async throws -> R) async throws -> R {
        try await body(RouteStream(receive: { nil }, write: { bytes in
            received.withLock { $0.append(bytes) }
        }, finishWriting: {}))
    }
}

@Test func proxyUpstreamEOFKeepsClientWritesOpen() async throws {
    let upstream = HalfClosedUpstream()
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: upstream)
    proxy.setDestinations([.init(host: "test.localhost", port: 80)])
    try await client(proxy.port) { peer in
        try await authenticate(peer, proxy)
        #expect(try await connect(peer, port: 80) == 0)
        #expect(try await peer.input.next() == nil)
        try await peer.send(Data([1, 2, 3]))
        peer.output.finish()
        let end = ContinuousClock.now + .seconds(2)
        while upstream.received.withLock({ $0.count }) != 3 && ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(upstream.received.withLock { $0 } == Data([1, 2, 3]))
    }
    await proxy.stop()
}

@Test func removingProxyDestinationClosesItsConnectedClient() async throws {
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: TestOpener())
    proxy.setDestinations([.init(host: "test.localhost", port: 80)])
    try await client(proxy.port) { peer in
        try await authenticate(peer, proxy)
        #expect(try await connect(peer, port: 80) == 0)
        let start = ContinuousClock.now
        proxy.setDestinations([])
        let eof = try await peer.input.next()
        #expect(eof == nil)
        #expect(start.duration(to: .now) < .seconds(4))
    }
    await proxy.stop()
}

@Test func restartingGateInvalidatesUnusedGrants() async throws {
    let registry = GateRegistry()
    let first = try await LocalhostGate.start(port: 0, registry: registry)
    let token = registry.register(profile: UUID(), privateName: "test.localhost", ports: [first.port],
                                  origins: [], opener: TestOpener())
    await first.stop()
    let next = try await LocalhostGate.start(port: first.port, registry: registry)
    try await client(next.port) { peer in
        try await peer.send(request("localhost:\(next.port)", ["User-Agent: " + token.userAgentComponent]))
        #expect(try await response(peer).0 == 403)
    }
    await next.stop()
}

@Test func servedPortsFollowListenerAndProfileLifetimes() async throws {
    let registry = GateRegistry(), profile = UUID(), other = UUID()
    let first = try await LocalhostGate.start(port: 0, registry: registry)
    let second = try await LocalhostGate.start(port: 0, registry: registry)
    let token = registry.register(profile: profile, privateName: "one.localhost", ports: [first.port, second.port, 0],
                                  origins: [], opener: TestOpener())
    _ = registry.register(profile: other, privateName: "two.localhost", ports: [second.port],
                          origins: [], opener: TestOpener())
    #expect(registry.servedPorts(for: profile) == [first.port, second.port])
    #expect(registry.servedPorts(for: other) == [second.port])
    try await client(second.port) { peer in
        try await peer.send(request("localhost:\(second.port)", ["User-Agent: " + token.userAgentComponent]))
        #expect(try await response(peer).0 == 200)
        await registry.revokeAll(for: profile)
        #expect(try await peer.input.next() == nil)
    }
    #expect(registry.servedPorts(for: profile).isEmpty)
    #expect(registry.servedPorts(for: other) == [second.port])
    await first.stop()
    await second.stop()
    #expect(registry.servedPorts(for: other).isEmpty)
}

@Test func sixParallelProxyOpensSurviveASlowUpstream() async throws {
    let opener = TestOpener(openDelay: .milliseconds(120))
    for limit in [ProxyLimits().pendingOpens, 2] {
        var limits = ProxyLimits()
        limits.pendingOpens = limit
        let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: opener, limits: limits)
        proxy.setDestinations([.init(host: "test.localhost", port: 80)])
        try await withThrowingTaskGroup(of: UInt8.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await client(proxy.port) { peer in
                        try await authenticate(peer, proxy)
                        return try await connect(peer, port: 80)
                    }
                }
            }
            for try await code in group { #expect(code == 0) }
        }
        await proxy.stop()
    }
}

@Test func proxyQueueRefusesOnlyAtCapacityOrDeadline() async throws {
    var limits = ProxyLimits()
    #expect(limits.pendingOpens == 8)
    #expect(limits.queuedOpens == 32)
    #expect(limits.queueTimeout == .seconds(10))
    limits.pendingOpens = 0
    limits.queuedOpens = 1
    limits.queueTimeout = .milliseconds(600)
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: TestOpener(), limits: limits)
    proxy.setDestinations([.init(host: "test.localhost", port: 80)])
    let waits = try await withThrowingTaskGroup(of: Duration.self) { group in
        for _ in 0..<2 {
            group.addTask {
                try await client(proxy.port) { peer in
                    try await authenticate(peer, proxy)
                    let start = ContinuousClock.now
                    #expect(try await connect(peer, port: 80) == 1)
                    return start.duration(to: .now)
                }
            }
        }
        return try await group.reduce(into: []) { $0.append($1) }.sorted()
    }
    #expect(waits.first! < .milliseconds(400))
    #expect(waits.last! >= .milliseconds(600))
    await proxy.stop()
}

@Test func proxyExternalApproval() async throws {
    let opener = TestOpener()
    let calls = OSAllocatedUnfairLock(initialState: [String]())
    let remembered = OSAllocatedUnfairLock(initialState: Set<ProxyDestination>())
    var limits = ProxyLimits()
    limits.approvalTimeout = .milliseconds(150)
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: opener, limits: limits) { destination in
        #expect(destination.port == 443)
        calls.withLock { $0.append(destination.host) }
        switch destination.host {
        case "once": return .allowOnce
        case "saved":
            remembered.withLock { _ = $0.insert(destination) }
            return .allowAndRemember
        case "slow":
            try? await Task.sleep(for: .seconds(10))
            return .allowOnce
        default: return .refuse
        }
    }
    for (name, code): (String, UInt8) in [("once", 0), ("once", 0), ("saved", 0), ("saved", 0), ("other", 2),
                                            ("slow", 2), ("127.0.2.1", 2), ("::1", 2), ("else.localhost.", 2)] {
        proxy.setDestinations(remembered.withLock { $0 })
        try await client(proxy.port) { peer in
            try await authenticate(peer, proxy)
            #expect(try await connect(peer, port: 443, name: name) == code)
        }
    }
    #expect(calls.withLock { $0 } == ["once", "once", "saved", "other", "slow"])
    #expect(opener.state.withLock { $0.hosts } == ["once", "once", "saved", "saved"])
    await proxy.stop()
}
#endif
