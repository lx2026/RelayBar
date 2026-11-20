import Foundation
import NIOCore
import os

public struct GateToken: Sendable {
    public static let cookieName = "__relay"
    static let cookiePrefix = cookieName + "_"
    public static func cookieName(for port: UInt16) -> String { cookiePrefix + String(port) }
    static let agentPrefix = "RelayBar/"
    public let value: String
    public var userAgentComponent: String { Self.agentPrefix + value }
    fileprivate let id = UUID()
}

public final class GateRegistry: Sendable {
    struct Service: Sendable {
        let token: GateToken
        let profile: UUID
        let privateName: String
        let ports: Set<UInt16>
        let origins: Set<String>
        let opener: any RouteStreamOpener

        func accepts(origin: String) -> Bool {
            guard let parts = URLComponents(string: origin), let scheme = parts.scheme,
                  ["http", "https"].contains(scheme), let host = parts.host else { return false }
            let port = parts.port
            guard port.map({ (1...65535).contains($0) }) ?? true,
                  origin == "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") else { return false }
            if host == privateName && host.hasSuffix(".localhost") { return true }
            return ["localhost", "127.0.0.1", "[::1]"].contains(host) && origins.contains(origin)
        }
    }
    private struct Connection {
        let channel: Channel
        var profile: UUID?
        var tokens = Set<UUID>()
        var revoked = false
    }
    private struct State {
        var listeners = [UInt16: UUID]()
        var services = [UUID: Service]()
        var connections = [ObjectIdentifier: Connection]()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// A service grant works only on these destination ports. Origins use serialized web-origin syntax.
    public func register(profile: UUID, privateName: String, ports: Set<UInt16>, origins: Set<String>,
                         opener: any RouteStreamOpener) -> GateToken {
        let token = GateToken(value: secret())
        let service = Service(token: token, profile: profile, privateName: privateName.lowercased(),
                              ports: ports, origins: origins, opener: opener)
        state.withLock { $0.services[token.id] = service }
        return token
    }

    public func servedPorts(for profile: UUID) -> Set<UInt16> {
        state.withLock { state in
            let granted = state.services.values.filter { $0.profile == profile }.flatMap(\.ports)
            return Set(state.listeners.keys).intersection(granted)
        }
    }

    func started(port: UInt16, listener: UUID) {
        state.withLock { $0.listeners[port] = listener }
    }

    func stopped(port: UInt16, listener: UUID) async {
        await revokeGrants { state in
            guard state.listeners[port] == listener else { return [] }
            state.listeners.removeValue(forKey: port)
            return state.services.values.filter { $0.ports.contains(port) }.map { $0.token.id }
        }
    }

    public func revoke(_ token: GateToken) async {
        await revokeGrants { _ in [token.id] }
    }

    public func revokeAll(for profile: UUID) async {
        await revokeGrants { state in
            state.services.values.filter { $0.profile == profile }.map { $0.token.id }
        }
    }

    private func revokeGrants(_ select: @Sendable (inout State) -> [UUID]) async {
        let clients = state.withLock { state in
            let ids = Set(select(&state))
            for id in ids { state.services.removeValue(forKey: id) }
            let clients = state.connections.values.filter { !$0.tokens.isDisjoint(with: ids) }
            for client in clients { state.connections[ObjectIdentifier(client.channel)]?.revoked = true }
            return clients.map(\.channel)
        }
        for client in clients { try? await client.close() }
    }

    func forget(_ client: ObjectIdentifier) {
        state.withLock { _ = $0.connections.removeValue(forKey: client) }
    }

    func active(_ service: Service) -> Bool {
        state.withLock { $0.services[service.token.id] != nil }
    }

    func authorize(_ request: GateRequest, port: UInt16, listener: UUID, channel: Channel) throws -> Service {
        let headers = request.head.headers
        return try state.withLock { state in
            guard state.listeners[port] == listener else { throw GateRefusal.token }
            let hosts = headers["host"].map { $0.lowercased() }
            guard hosts.count == 1, ["localhost", "127.0.0.1", "[::1]"].contains(where: {
                hosts[0] == "\($0):\(port)" || (port == 80 && hosts[0] == $0)
            }) else { throw GateRefusal.host }
            let sites = headers["sec-fetch-site"], modes = headers["sec-fetch-mode"]
            let site = sites.first?.trimmingCharacters(in: .whitespaces).lowercased()
            let mode = modes.first?.trimmingCharacters(in: .whitespaces).lowercased()
            let destinations = headers["sec-fetch-dest"].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard sites.count <= 1, modes.count <= 1, destinations.count <= 1,
                  site.map({ ["none", "same-origin", "same-site", "cross-site"].contains($0) }) ?? true,
                  site != "cross-site" || (mode == "navigate" && destinations == ["document"])
            else { throw GateRefusal.site }
            let presented = state.services.values.filter { service in
                request.credentials.contains { matches($0, service.token.value) }
            }
            guard let service = presented.first(where: { $0.ports.contains(port) }),
                  presented.allSatisfy({ $0.profile == service.profile }) else { throw GateRefusal.token }
            let origins = headers["origin"]
            guard origins.count <= 1, origins.allSatisfy({ origin in
                state.services.values.contains { $0.profile == service.profile && $0.accepts(origin: origin) }
            }) else { throw GateRefusal.origin }
            let client = ObjectIdentifier(channel)
            var connection = state.connections[client] ?? Connection(channel: channel)
            guard !connection.revoked, connection.profile == nil || connection.profile == service.profile else { throw GateRefusal.profile }
            connection.profile = service.profile
            connection.tokens.formUnion(presented.map { $0.token.id })
            state.connections[client] = connection
            return service
        }
    }
}
