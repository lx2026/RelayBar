import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1

enum GateRefusal: String, Error {
    case head = "Invalid request head"
    case host = "Invalid local host"
    case origin = "Origin refused"
    case site = "Cross-site request refused"
    case token = "Service credential refused"
    case profile = "Connection belongs to another profile"
    case upgrade = "Unsupported upgrade"
    case framing = "Unsupported request framing"
}

struct GateRequest: Sendable {
    var head: HTTPRequestHead
    let websocket: Bool
    let chunked: Bool
    let length: Int
    let close: Bool
    let credentials: [String]

    // A fresh synchronous decoder consumes exactly one bounded head. Body bytes and
    // pipelined requests stay in SocketReader until this request has been authorized.
    init(bytes: [UInt8], port: UInt16) throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
        defer { _ = try? channel.finish() }
        try channel.writeInbound(ByteBuffer(bytes: bytes))
        guard case .head(var head) = try channel.readInbound(as: HTTPServerRequestPart.self),
              head.version == .http1_1, head.uri.hasPrefix("/"),
              !head.uri.contains("#"), head.method != .CONNECT else { throw GateRefusal.head }
        let connections = head.headers[canonicalForm: "connection"].map { $0.lowercased() }
        close = connections.contains("close")
        let upgrades = head.headers["upgrade"].map { $0.lowercased() }
        websocket = upgrades == ["websocket"] && connections.contains("upgrade") && head.method == .GET
        guard websocket || (upgrades.isEmpty && !connections.contains("upgrade")) else { throw GateRefusal.upgrade }
        let encoding = head.headers["transfer-encoding"].map { $0.lowercased() }
        let sizes = head.headers["content-length"]
        guard sizes.count <= 1, encoding.isEmpty || (encoding == ["chunked"] && sizes.isEmpty) else {
            throw GateRefusal.framing
        }
        chunked = !encoding.isEmpty
        if let size = sizes.first {
            guard size.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(size) else { throw GateRefusal.framing }
            length = value
        } else { length = 0 }
        guard !websocket || (!chunked && length == 0) else { throw GateRefusal.framing }

        var tokens = [String]()
        let agents = head.headers["user-agent"]
        guard agents.count <= 1 else { throw GateRefusal.token }
        head.headers.remove(name: "user-agent")
        if let agent = agents.first {
            let words = agent.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { word in
                guard word.hasPrefix(GateToken.agentPrefix) else { return true }
                tokens.append(String(word.dropFirst(GateToken.agentPrefix.count)))
                return false
            }
            if !words.isEmpty { head.headers.add(name: "User-Agent", value: words.joined(separator: " ")) }
        }
        let cookies = head.headers["cookie"].flatMap { $0.split(separator: ";") }.map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { pair in
            let fields = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(GateToken.cookiePrefix) else { return true }
            if name == GateToken.cookieName(for: port), fields.count == 2 {
                tokens.append(String(fields[1]))
            }
            return false
        }
        head.headers.remove(name: "cookie")
        if !cookies.isEmpty { head.headers.add(name: "Cookie", value: cookies.joined(separator: "; ")) }
        credentials = tokens
        self.head = head
    }

    var encoded: Data {
        var headers = head.headers
        headers.replaceOrAdd(name: "Connection", value: websocket ? "Upgrade" : "close")
        var text = "\(head.method.rawValue) \(head.uri) HTTP/1.1\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    func sendBody(from reader: SocketReader, to stream: RouteStream, limit: Int) async throws {
        func copy(count: Int) async throws {
            var left = count
            while left > 0 {
                guard let bytes = try await reader.next(maximum: left) else { throw RouteError.closed }
                try await stream.write(bytes)
                left -= bytes.count
            }
        }
        guard chunked else { try await copy(count: length); return }
        while true {
            let line = try await reader.through([13, 10], limit: limit)
            let digits = line.dropLast(2).prefix { $0 != 59 }
            guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let size = Int(String(decoding: digits, as: UTF8.self), radix: 16) else { throw GateRefusal.framing }
            if size == 0 {
                // Consume the bounded trailer section locally. A trailer cannot inject a
                // credential, change framing, or turn into a second unchecked head.
                var available = limit
                while true {
                    let trailer = try await reader.through([13, 10], limit: available)
                    available -= trailer.count
                    if trailer.count == 2 { break }
                }
                try await stream.write(Data("0\r\n\r\n".utf8))
                return
            }
            try await stream.write(Data((String(size, radix: 16) + "\r\n").utf8))
            try await copy(count: size)
            guard try await reader.read(2) == [13, 10] else { throw GateRefusal.framing }
            try await stream.write(Data([13, 10]))
        }
    }
}
