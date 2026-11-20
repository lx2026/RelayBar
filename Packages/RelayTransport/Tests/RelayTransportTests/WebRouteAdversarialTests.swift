#if os(macOS)
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import os
import RelayTransport
@testable import RelayWebRoutes
import Testing

// Adversarial cases for the gate and the proxy. Each refused form is one a client could
// use to make the gate and a typical upstream disagree, or to reuse a partial credential.

private final class ProbeCursor: @unchecked Sendable {
    var iterator: AsyncStream<Data>.Iterator
    init(_ input: AsyncStream<Data>) { iterator = input.makeAsyncIterator() }
    func next() async -> Data? { await iterator.next() }
}

/// Echoes writes, or answers each write with a fixed reply.
private struct ScriptedOpener: RouteStreamOpener {
    var reply: String?
    var failure: TransportError?
    var isReconnecting: Bool { false }
    func withRouteStream<R: Sendable>(host: String, port: UInt16,
        _ body: @escaping @Sendable (RouteStream) async throws -> R) async throws -> R {
        if let failure { throw failure }
        let (input, sender) = AsyncStream<Data>.makeStream()
        let cursor = ProbeCursor(input)
        defer { sender.finish() }
        return try await body(RouteStream(receive: { await cursor.next() }, write: { [reply] bytes in
            sender.yield(reply.map { Data($0.utf8) } ?? bytes)
        }, finishWriting: { sender.finish() }))
    }
}

private func raw(_ lines: [String]) -> [UInt8] { Array((lines + ["", ""]).joined(separator: "\r\n").utf8) }

private func probe<R: Sendable>(_ port: UInt16, _ body: @escaping @Sendable (Peer) async throws -> R) async throws -> R {
    let socket = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .connect(host: "127.0.0.1", port: Int(port)) { channel in
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

private func everything(_ peer: Peer) async throws -> String {
    var all = Data()
    while let part = try await peer.input.next() { all.append(part) }
    return String(decoding: all, as: UTF8.self)
}

@Test func gateRefusesAmbiguousHeads() {
    let host = "Host: localhost:8080"
    let refused: [(String, [UInt8])] = [
        ("TE and CL", raw(["POST / HTTP/1.1", host, "Transfer-Encoding: chunked", "Content-Length: 4"])),
        ("duplicate CL", raw(["POST / HTTP/1.1", host, "Content-Length: 4", "Content-Length: 4"])),
        ("CL list", raw(["POST / HTTP/1.1", host, "Content-Length: 4, 4"])),
        ("signed CL", raw(["POST / HTTP/1.1", host, "Content-Length: +4"])),
        ("TE twice", raw(["POST / HTTP/1.1", host, "Transfer-Encoding: chunked, chunked"])),
        ("TE identity", raw(["POST / HTTP/1.1", host, "Transfer-Encoding: identity"])),
        ("TE coding", raw(["POST / HTTP/1.1", host, "Transfer-Encoding: gzip, chunked"])),
        ("TE split", raw(["POST / HTTP/1.1", host, "Transfer-Encoding: gzip", "Transfer-Encoding: chunked"])),
        ("HTTP/1.0", raw(["GET / HTTP/1.0", host])),
        ("HTTP/2 preface", Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)),
        ("absolute form", raw(["GET http://localhost:8080/ HTTP/1.1", host])),
        ("CONNECT", raw(["CONNECT localhost:8080 HTTP/1.1", host])),
        ("asterisk form", raw(["OPTIONS * HTTP/1.1", host])),
        ("h2c", raw(["GET / HTTP/1.1", host, "Connection: Upgrade, HTTP2-Settings", "Upgrade: h2c"])),
        ("WebSocket POST", raw(["POST / HTTP/1.1", host, "Connection: Upgrade", "Upgrade: websocket"])),
        ("upgrade list", raw(["GET / HTTP/1.1", host, "Connection: Upgrade", "Upgrade: websocket, h2c"])),
        ("upgrade token alone", raw(["GET / HTTP/1.1", host, "Connection: Upgrade"])),
        ("WebSocket body", raw(["GET / HTTP/1.1", host, "Connection: Upgrade", "Upgrade: websocket", "Content-Length: 1"])),
        ("duplicate user agent", raw(["GET / HTTP/1.1", host, "User-Agent: a", "User-Agent: b"])),
        ("bare LF", Array("GET / HTTP/1.1\nHost: localhost:8080\n\r\n\r\n".utf8)),
        ("obs-fold", raw(["GET / HTTP/1.1", host, "X-A: a", " Transfer-Encoding: chunked"])),
        ("space before colon", raw(["GET / HTTP/1.1", host, "Transfer-Encoding : chunked"])),
        ("fragment", raw(["GET /#x HTTP/1.1", host])),
    ]
    for (name, bytes) in refused {
        #expect(throws: (any Error).self, "\(name)") { _ = try GateRequest(bytes: bytes, port: 8080) }
    }
}

@Test func gateStripsEveryCredentialForm() throws {
    let token = String(repeating: "ab", count: 16)
    for fields in [["User-Agent: RelayBar/\(token)"], ["User-Agent: A RelayBar/\(token) B"],
                   ["User-Agent: A\tRelayBar/\(token)"], ["Cookie: __relay_8080=\(token)"],
                   ["Cookie: a=1; __relay_8080=\(token); b=2"], ["Cookie: a=1;__relay_8080=\(token)"],
                   ["Cookie: a=1", "Cookie: __relay_8080=\(token)"], ["Cookie: __relay_8080 =\(token)"],
                   ["User-Agent: RelayBar/\(token)", "Cookie: __relay_8080=\(token)"]] {
        let request = try GateRequest(bytes: raw(["GET / HTTP/1.1", "Host: localhost:8080"] + fields), port: 8080)
        let text = String(decoding: request.encoded, as: UTF8.self)
        let stripped = !text.contains(token)
        let recognized = request.credentials.contains(token)
        let emptyHeader = text.contains("Cookie: \r\n") || text.contains("User-Agent: \r\n")
        #expect(stripped)
        #expect(recognized)
        #expect(!emptyHeader)
    }
}

@Test func gateRefusesNearMissHostsTokensAndOrigins() {
    let registry = GateRegistry(), listener = UUID()
    registry.started(port: 8080, listener: listener)
    let token = registry.register(profile: UUID(), privateName: "one.localhost", ports: [8080],
                                  origins: ["http://localhost:8080"], opener: ScriptedOpener())
    let ua = "User-Agent: RelayBar/" + token.value
    func authorized(_ fields: [String]) -> Bool {
        guard let request = try? GateRequest(bytes: raw(["GET / HTTP/1.1"] + fields), port: 8080) else { return false }
        return (try? registry.authorize(request, port: 8080, listener: listener, channel: EmbeddedChannel())) != nil
    }
    func expectAuthorization(_ expected: Bool, _ fields: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let allowed = authorized(fields)
        #expect(allowed == expected, sourceLocation: sourceLocation)
    }
    for host in ["localhost:8080", "LOCALHOST:8080", "127.0.0.1:8080", "[::1]:8080"] {
        expectAuthorization(true, ["Host: " + host, ua])
    }
    for host in ["localhost.:8080", "localhost", "localhost:08080", "127.1:8080", "[0:0:0:0:0:0:0:1]:8080",
                 "[::ffff:127.0.0.1]:8080", "0x7f.0.0.1:8080", "2130706433:8080", "user@localhost:8080",
                 "localhost:8080.", "one.localhost:8080", "localhost:8080, localhost:8080"] {
        expectAuthorization(false, ["Host: " + host, ua])
    }
    expectAuthorization(false, ["Host: localhost:8080", "Host: evil.test", ua])
    for candidate in [String(token.value.dropLast()), token.value + "0", token.value.uppercased(), " " + token.value, ""] {
        expectAuthorization(false, ["Host: localhost:8080", "User-Agent: RelayBar/" + candidate])
        expectAuthorization(false, ["Host: localhost:8080", "Cookie: __relay_8080=" + candidate])
    }
    for fields in [["User-Agent: relaybar/" + token.value], ["Cookie: __Relay_8080=" + token.value],
                   ["Cookie: __relay_8080=\"\(token.value)\""]] {
        expectAuthorization(false, ["Host: localhost:8080"] + fields)
    }
    for origin in ["null", "http://localhost:8080/", "http://localhost:8080:8080", "http://one.localhost.:8080",
                   "http://localhost", "https://localhost:8080", "http://127.0.0.1:8080", "http://one%2elocalhost",
                   "http://two.localhost", "http://x.one.localhost", "file://"] {
        expectAuthorization(false, ["Host: localhost:8080", ua, "Origin: " + origin])
    }
    for site in [["Sec-Fetch-Site: Cross-Site", "Sec-Fetch-Mode: cors"], ["Sec-Fetch-Site: cross-site"],
                 ["Sec-Fetch-Site: cross-site", "Sec-Fetch-Mode: navigate", "Sec-Fetch-Mode: cors"],
                 ["Sec-Fetch-Site: cross-site, same-origin"], ["Sec-Fetch-Site: unknown"]] {
        expectAuthorization(false, ["Host: localhost:8080", ua] + site)
    }
}

@Test func gateAdmitsAPageWorthOfParallelConnections() async throws {
    let gate = try await LocalhostGate.start(port: 0)
    let token = gate.registry.register(profile: UUID(), privateName: "p.localhost", ports: [gate.port],
                                       origins: [], opener: ScriptedOpener(failure: .connectionRefused))
    let request = Data(raw(["GET / HTTP/1.1", "Host: localhost:\(gate.port)", "User-Agent: " + token.userAgentComponent]))
    let replies = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<6 {
            group.addTask {
                do {
                    return try await probe(gate.port) { peer in
                        try await peer.send(request)
                        return String(try await everything(peer).prefix(12))
                    }
                } catch { return "reset" }
            }
        }
        return try await group.reduce(into: [String]()) { $0.append($1) }
    }
    #expect(replies == Array(repeating: "HTTP/1.1 502", count: 6))
    await gate.stop()
}

@Test func gateRelaysOnlyAConfirmedWebSocketSwitch() async throws {
    let ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    for (reply, expected) in [(ok, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"),
                              ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: h2c\r\nConnection: Upgrade\r\n\r\n", ""),
                              ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n", "")] {
        let gate = try await LocalhostGate.start(port: 0)
        let token = gate.registry.register(profile: UUID(), privateName: "p.localhost", ports: [gate.port],
                                           origins: [], opener: ScriptedOpener(reply: reply))
        let upgrade = raw(["GET / HTTP/1.1", "Host: localhost:\(gate.port)", "User-Agent: " + token.userAgentComponent,
                           "Connection: Upgrade", "Upgrade: websocket", "Sec-WebSocket-Version: 13",
                           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="])
        let received = try await probe(gate.port) { peer in
            // Bytes sent before the switch must never be read as a second request.
            try await peer.send(Data(upgrade) + Data(raw(["GET /second HTTP/1.1", "Host: localhost"])))
            return try await everything(peer)
        }
        #expect(received == expected)
        await gate.stop()
    }
}

@Test func proxyRefusesDestinationLookalikes() async throws {
    let proxy = try await SOCKSProxy.start(privateName: "test.localhost", opener: ScriptedOpener())
    proxy.setDestinations([.init(host: "test.localhost", port: 80)])
    func name(_ text: String) -> [UInt8] { [3, UInt8(text.utf8.count)] + Array(text.utf8) }
    let mapped: [UInt8] = [4] + Array(repeating: 0, count: 10) + [255, 255, 127, 0, 0, 1]
    let cases: [([UInt8], UInt8)] = [
        (name("test.localhost"), 0), (name("TEST.LOCALHOST"), 0), (name("test.localhost."), 2),
        (name("test.localhost\u{0}"), 2), (name("[::1]"), 2), (name("127.1"), 2), (name("2130706433"), 2),
        ([1, 127, 0, 0, 1], 2), (mapped, 2), (name("localhost"), 2), (name("x.test.localhost"), 2),
        ([3, 15] + Array("test.localhost".utf8) + [0xe9], 8),
    ]
    for (address, expected) in cases {
        let code = try await probe(proxy.port) { peer in
            try await peer.send(Data([5, 1, 2]))
            _ = try await peer.input.read(2)
            let user = Array(proxy.username.utf8), password = Array(proxy.password.utf8)
            try await peer.send(Data([1, UInt8(user.count)] + user + [UInt8(password.count)] + password))
            #expect(try await peer.input.read(2) == [1, 0])
            try await peer.send(Data([5, 1, 0] + address + [0, 80]))
            return try await peer.input.read(10)[1]
        }
        #expect(code == expected, "\(address)")
    }
    await proxy.stop()
}
#endif
