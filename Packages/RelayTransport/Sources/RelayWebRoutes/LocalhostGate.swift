import Foundation
import NIOCore
import NIOHTTP1
import os
import RelayTransport

public struct GateLimits: Sendable {
    public var headBytes = 16 * 1024
    public var headTimeout: TimeAmount = .seconds(45)
    // WebKit opens up to six connections per host at once, per data store, and two
    // profiles can share a port. A lower bound resets the app's own page loads.
    public var unvalidatedSockets = 16
    public init() {}
}

public final class LocalhostGate: Sendable {
    public let registry: GateRegistry
    private let id = UUID()
    private let boundPort = OSAllocatedUnfairLock(initialState: UInt16(0))
    private let listeners = Listeners()
    private let limits: GateLimits
    private init(registry: GateRegistry, limits: GateLimits) {
        self.registry = registry
        self.limits = limits
    }
    public var port: UInt16 { boundPort.withLock { $0 } }

    public static func start(port: UInt16, registry: GateRegistry = .init(), limits: GateLimits = .init()) async throws -> LocalhostGate {
        let gate = LocalhostGate(registry: registry, limits: limits)
        _ = try await gate.listeners.bind(port: port, dual: true, capacity: .max,
            pendingCapacity: limits.unvalidatedSockets, evictOldest: true, onBound: { actual in
                gate.boundPort.withLock { $0 = actual }
                registry.started(port: actual, listener: gate.id)
            }) { [weak gate] peer in
                await gate?.serve(peer)
            }
        return gate
    }

    public func stop() async {
        await registry.stopped(port: port, listener: id)
        await listeners.stop()
    }

    private func page(_ status: String, _ reason: String, to peer: Peer) async {
        let body = "<!doctype html><title>\(status)</title><p>\(reason)</p>"
        let response = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        try? await peer.send(Data(response.utf8))
    }

    private func serve(_ peer: Peer) async {
        let client = ObjectIdentifier(peer.channel)
        defer { registry.forget(client) }
        while !Task.isCancelled {
            let request: GateRequest
            let service: GateRegistry.Service
            do {
                let timer = peer.timeout(limits.headTimeout)
                defer { timer.cancel() }
                request = try await GateRequest(bytes: peer.input.through([13, 10, 13, 10], limit: limits.headBytes), port: port)
                service = try registry.authorize(request, port: port, listener: id, channel: peer.channel)
                guard listeners.validated(client) else { return }
            } catch RouteError.closed { return }
            catch {
                await page("403 Forbidden", (error as? GateRefusal ?? .head).rawValue, to: peer)
                return
            }
            let connected = OSAllocatedUnfairLock(initialState: false)
            do {
                let reusable = try await service.opener.withRouteStream(host: "127.0.0.1", port: port) { stream in
                    try Task.checkCancellation()
                    guard peer.channel.isActive, self.registry.active(service)
                    else { throw RouteError.closed }
                    connected.withLock { $0 = true }
                    try await stream.write(request.encoded)
                    return try await exchange(request, peer: peer, upstream: stream, limit: self.limits.headBytes)
                }
                if !reusable { return }
            } catch {
                if !connected.withLock({ $0 }) {
                    let reason: String
                    switch error as? TransportError {
                    case .connectionRefused: reason = "Service refused the connection"
                    case .forwardingProhibited: reason = "SSH forwarding denied"
                    case .unreachable: reason = "Host unreachable"
                    default: reason = "SSH stream unavailable"
                    }
                    await page("502 Bad Gateway", reason, to: peer)
                }
                return
            }
        }
    }
}
