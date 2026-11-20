import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import os

private func responseHead(_ bytes: Data, for request: HTTPRequestHead) throws -> HTTPResponseHead {
    let decoder = HTTPResponseDecoder(informationalResponseStrategy: .forward)
    decoder.write(data: .head(request))
    let channel = EmbeddedChannel(handler: ByteToMessageHandler(decoder))
    defer { _ = try? channel.finish() }
    try channel.writeInbound(ByteBuffer(bytes: bytes))
    guard case .head(let head) = try channel.readInbound(as: HTTPClientResponsePart.self) else {
        throw RouteError.malformed
    }
    return head
}

private func encode(_ head: HTTPResponseHead) -> Data {
    var text = "HTTP/1.1 \(head.status.code) \(head.status.reasonPhrase)\r\n"
    for (name, value) in head.headers { text += "\(name): \(value)\r\n" }
    return Data((text + "\r\n").utf8)
}

private func response(_ request: GateRequest, peer: Peer, upstream: RouteStream, limit: Int) async throws -> Bool {
    var pending = Data()
    let separator = Data([13, 10, 13, 10])
    var head: HTTPResponseHead
    while true {
        var from = pending.startIndex
        while pending.range(of: separator, in: from..<pending.endIndex) == nil {
            guard pending.count < limit, let bytes = try await upstream.receive() else { throw RouteError.malformed }
            from = max(pending.startIndex, pending.endIndex - 3)
            pending.append(bytes)
        }
        let end = pending.range(of: separator, in: from..<pending.endIndex)!.upperBound
        guard end - pending.startIndex <= limit else { throw RouteError.oversized }
        head = try responseHead(pending.prefix(upTo: end), for: request.head)
        pending.removeSubrange(..<end)
        if head.status.code >= 200 || head.status.code == 101 { break }
        try await peer.send(encode(head))
    }
    if head.status.code == 101 {
        guard request.websocket, head.headers["upgrade"].map({ $0.lowercased() }) == ["websocket"],
              head.headers[canonicalForm: "connection"].contains(where: { $0.lowercased() == "upgrade" })
        else { throw RouteError.malformed }
        try await peer.send(encode(head))
        if !pending.isEmpty { try await peer.send(pending) }
        try await relay(peer, upstream)
        return false
    }
    let empty = request.head.method == .HEAD || [204, 304].contains(head.status.code)
    let size = empty ? 0 : Int(head.headers.first(name: "content-length") ?? "")
    let reusable = size != nil && !request.close && !request.websocket && !head.headers.contains(name: "transfer-encoding")
    head.headers.replaceOrAdd(name: "Connection", value: reusable ? "keep-alive" : "close")
    try await peer.send(encode(head))
    if let size {
        guard size >= 0 else { throw RouteError.malformed }
        var left = size
        while left > 0 {
            if pending.isEmpty {
                guard let data = try await upstream.receive() else { throw RouteError.closed }
                pending = data
            }
            let chunk = pending.prefix(left)
            try await peer.send(chunk)
            left -= chunk.count
            pending = Data()
        }
    } else {
        if !pending.isEmpty { try await peer.send(pending) }
        while let data = try await upstream.receive() { try await peer.send(data) }
    }
    return reusable
}

func exchange(_ request: GateRequest, peer: Peer, upstream: RouteStream, limit: Int) async throws -> Bool {
    if request.websocket { return try await response(request, peer: peer, upstream: upstream, limit: limit) }
    if !request.chunked && request.length == 0 {
        upstream.finishWriting()
        return try await response(request, peer: peer, upstream: upstream, limit: limit)
    }
    // Read responses while uploading, including 100 Continue and early final responses.
    let uploaded = OSAllocatedUnfairLock(initialState: false)
    return try await withThrowingTaskGroup(of: Bool?.self) { group in
        group.addTask {
            try await request.sendBody(from: peer.input, to: upstream, limit: limit)
            uploaded.withLock { $0 = true }
            upstream.finishWriting()
            return nil
        }
        group.addTask { try await response(request, peer: peer, upstream: upstream, limit: limit) }
        for try await reuse in group {
            if let reuse {
                guard uploaded.withLock({ $0 }) else {
                    group.cancelAll()
                    return false
                }
                return reuse
            }
        }
        return false
    }
}
