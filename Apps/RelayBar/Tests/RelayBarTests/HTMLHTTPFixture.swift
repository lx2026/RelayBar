import Foundation
import Network

/// Real HTTP responses for WebKit tests, confined to loopback.
final class HTMLHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let connections: LockedConnectionCount
    let baseURL: String

    /// Connections accepted so far, including any that never sent a request.
    var connectionCount: Int { connections.value }

    init(files: [String: String]) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let connections = LockedConnectionCount()
        self.listener = listener
        self.connections = connections
        listener.newConnectionHandler = { connection in
            connections.increment()
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let path = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let body = Data((files[path] ?? "missing").utf8)
                let mime = path.hasSuffix(".js") ? "text/javascript" : path.hasSuffix(".css") ? "text/css" : "application/json"
                let header = "HTTP/1.1 \(files[path] == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(mime)\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        baseURL = "http://127.0.0.1:\(port)"
    }
    func stop() { listener.cancel() }
}

private final class LockedConnectionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
