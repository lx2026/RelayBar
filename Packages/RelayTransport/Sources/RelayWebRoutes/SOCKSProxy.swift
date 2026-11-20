import Darwin
import Foundation
import NIOCore
import os
import RelayTransport

public struct ProxyDestination: Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host.lowercased(); self.port = port }
}

public enum ProxyApproval: Sendable { case allowOnce, allowAndRemember, refuse }
public typealias ProxyApprovalHook = @Sendable (ProxyDestination) async -> ProxyApproval

public struct ProxyLimits: Sendable {
    public var streams = 16
    public var pendingOpens = 8
    public var queuedOpens = 32
    public var queueTimeout: Duration = .seconds(10)
    public var approvalTimeout: Duration = .seconds(30)
    public var handshake: TimeAmount = .seconds(5)
    public var reconnectHold: Duration = .seconds(5)
    public init() {}
}

public final class SOCKSProxy: Sendable {
    public let username = secret()
    public let password = secret()
    public var port: UInt16 { boundPort.withLock { $0 } }
    private let boundPort = OSAllocatedUnfairLock(initialState: UInt16(0))
    private let listeners = Listeners()
    private struct Routes {
        var allowed = Set<ProxyDestination>()
        var connected = [UUID: (destination: ProxyDestination, channel: Channel)]()
    }
    private let routes = OSAllocatedUnfairLock(initialState: Routes())
    private let admission: ProxyAdmission
    private let opener: any RouteStreamOpener
    private let privateName: String
    private let limits: ProxyLimits

    private let approval: ProxyApprovalHook?

    private init(privateName: String, opener: any RouteStreamOpener, limits: ProxyLimits, approval: ProxyApprovalHook?) {
        self.approval = approval
        self.privateName = privateName.lowercased()
        self.opener = opener
        self.limits = limits
        admission = ProxyAdmission(limits)
    }

    public static func start(privateName: String, opener: any RouteStreamOpener,
                             limits: ProxyLimits = .init()) async throws -> SOCKSProxy {
        try await start(privateName: privateName, opener: opener, limits: limits, approval: nil)
    }

    public static func start(privateName: String, opener: any RouteStreamOpener,
                             limits: ProxyLimits = .init(), approval: ProxyApprovalHook?) async throws -> SOCKSProxy {
        let proxy = SOCKSProxy(privateName: privateName, opener: opener, limits: limits, approval: approval)
        let queued = max(0, limits.queuedOpens)
        let capacity = min(Int.max - queued, max(0, limits.streams)) + queued
        let port = try await proxy.listeners.bind(port: 0, dual: false, capacity: capacity,
                                                  pendingCapacity: limits.streams) { [weak proxy] peer in
            await proxy?.serve(peer)
        }
        proxy.boundPort.withLock { $0 = port }
        return proxy
    }

    public func setDestinations(_ destinations: Set<ProxyDestination>) {
        let removed = routes.withLock { routes in
            let removed = routes.allowed.subtracting(destinations)
            routes.allowed = destinations
            return routes.connected.values.filter { removed.contains($0.destination) }.map(\.channel)
        }
        for channel in removed { channel.close(promise: nil) }
    }

    public func stop() async { await listeners.stop() }

    private func authenticate(_ peer: Peer) async throws {
        let greeting = try await peer.input.read(2)
        guard greeting[0] == 5 else { throw RouteError.malformed }
        guard try await peer.input.read(Int(greeting[1])).contains(2) else {
            try await peer.send(Data([5, 255]))
            throw RouteError.refused
        }
        try await peer.send(Data([5, 2]))
        let header = try await peer.input.read(2)
        let user = try await peer.input.read(Int(header[1]))
        let length = try await peer.input.read(1)[0]
        let pass = try await peer.input.read(Int(length))
        let authenticated = header[0] == 1 && matches(String(decoding: user, as: UTF8.self), username)
            && matches(String(decoding: pass, as: UTF8.self), password)
        try await peer.send(Data([1, authenticated ? 0 : 1]))
        guard authenticated else { throw RouteError.refused }
    }

    private func reply(_ code: UInt8, to peer: Peer) async throws {
        try await peer.send(Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]))
    }

    private static func external(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let localNames = ["localhost", "localhost.localdomain", "localhost4", "localhost4.localdomain4",
                          "localhost6", "localhost6.localdomain6", "ip6-localhost", "ip6-loopback"]
        guard !name.isEmpty, !name.utf8.contains(0), !localNames.contains(name),
              !name.hasSuffix(".localhost") else { return false }
        var v4 = in_addr()
        if inet_aton(name, &v4) == 1 {
            let address = UInt32(bigEndian: v4.s_addr)
            return address >> 24 != 127 && address != 0
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.prefix(12).allSatisfy({ $0 == 0 }) { return false }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10...11].allSatisfy({ $0 == 255 }) {
                return bytes[12] != 127 && bytes.suffix(4).contains(where: { $0 != 0 })
            }
            return true
        }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private func approved(_ destination: ProxyDestination, by hook: @escaping ProxyApprovalHook) async -> Bool {
        let (answers, sender) = AsyncStream<Bool>.makeStream()
        let deadline = ContinuousClock.now + limits.approvalTimeout
        let question = Task {
            let answer = await hook(destination)
            sender.yield(answer != .refuse && ContinuousClock.now < deadline)
        }
        let timeout = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            sender.finish()
        }
        defer { sender.finish(); question.cancel(); timeout.cancel() }
        var iterator = answers.makeAsyncIterator()
        return await iterator.next() == true
    }

    private func serve(_ peer: Peer) async {
        let timer = peer.timeout(limits.handshake)
        defer { timer.cancel() }
        do {
            try await authenticate(peer)
            let header = try await peer.input.read(4)
            guard header[0] == 5, header[2] == 0 else { return }
            guard header[1] == 1 else { try await reply(7, to: peer); return }
            let host: String
            switch header[3] {
            case 1, 4:
                let bytes = try await peer.input.read(header[3] == 1 ? 4 : 16)
                host = try SocketAddress(packedIPAddress: ByteBuffer(bytes: bytes), port: 0).ipAddress!
            case 3:
                let size = try await peer.input.read(1)[0]
                guard let name = String(bytes: try await peer.input.read(Int(size)), encoding: .ascii) else {
                    try await reply(8, to: peer)
                    return
                }
                host = name.lowercased()
            default: try await reply(8, to: peer); return
            }
            let bytes = try await peer.input.read(2)
            let destination = ProxyDestination(host: host, port: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            let mapped = [privateName, "localhost", "127.0.0.1", "::1"].contains(host)
            guard destination.port > 0, mapped || (approval != nil && Self.external(host)) else {
                try await reply(2, to: peer)
                return
            }
            timer.cancel()
            guard listeners.validated(ObjectIdentifier(peer.channel)) else { return }
            let granted: Bool
            if routes.withLock({ $0.allowed.contains(destination) }) {
                granted = false // Recheck the live allow-list before opening and acknowledging.
            } else if !mapped, let approval, await approved(destination, by: approval) {
                granted = true
            } else {
                try await reply(2, to: peer)
                return
            }
            let id = UUID()
            guard await admission.acquire(id) else { try await reply(1, to: peer); return }
            if await opener.isReconnecting {
                let end = ContinuousClock.now + limits.reconnectHold
                while await opener.isReconnecting && ContinuousClock.now < end && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            let opened = OSAllocatedUnfairLock(initialState: false)
            let openTimer = peer.timeout(limits.handshake)
            defer { openTimer.cancel() }
            do {
                guard !Task.isCancelled, !(await opener.isReconnecting) else { throw TransportError.unreachable }
                guard granted || routes.withLock({ $0.allowed.contains(destination) }) else { throw TransportError.forwardingProhibited }
                try await opener.withRouteStream(host: mapped && host != "::1" ? "127.0.0.1" : host, port: destination.port) { stream in
                    try Task.checkCancellation()
                    try self.routes.withLock { routes in
                        guard granted || routes.allowed.contains(destination) else { throw TransportError.forwardingProhibited }
                        routes.connected[id] = (destination, peer.channel)
                    }
                    defer { self.routes.withLock { _ = $0.connected.removeValue(forKey: id) } }
                    opened.withLock { $0 = true }
                    openTimer.cancel()
                    await self.admission.connected(id)
                    try await self.reply(0, to: peer)
                    try await relay(peer, stream)
                }
            } catch {
                await admission.finished(id)
                guard !opened.withLock({ $0 }) else { return }
                let code: UInt8
                switch error as? TransportError {
                case .connectionRefused: code = 5
                case .forwardingProhibited: code = 2
                case .unreachable, .disconnected: code = 4
                default: code = 1
                }
                try await reply(code, to: peer)
                return
            }
            await admission.finished(id)
        } catch { return }
    }
}
