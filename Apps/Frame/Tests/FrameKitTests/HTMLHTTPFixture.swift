import Foundation
import Network

/// Real HTTP responses for WebKit tests, confined to loopback.
final class HTMLHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    let baseURL: String

    init(files: [String: String]) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in
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
