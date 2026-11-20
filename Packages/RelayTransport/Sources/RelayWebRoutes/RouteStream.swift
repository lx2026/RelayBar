import Darwin
import Foundation
import NIOCore
import NIOPosix
import os
import RelayTransport

/// The opener scopes a connected stream to the callback. Each direction has one consumer.
public protocol RouteStreamOpener: Sendable {
    var isReconnecting: Bool { get async }
    func withRouteStream<R: Sendable>(host: String, port: UInt16,
                         _ body: @escaping @Sendable (RouteStream) async throws -> R) async throws -> R
}

public struct RouteStream: Sendable {
    public let receive: @Sendable () async throws -> Data?
    public let write: @Sendable (Data) async throws -> Void
    public let finishWriting: @Sendable () -> Void

    public init(receive: @escaping @Sendable () async throws -> Data?,
                write: @escaping @Sendable (Data) async throws -> Void,
                finishWriting: @escaping @Sendable () -> Void) {
        self.receive = receive
        self.write = write
        self.finishWriting = finishWriting
    }
}

// Swift async iterators are mutable. The relay assigns each cursor to one reader.
private final class SSHCursor: @unchecked Sendable {
    private var iterator: ForwardedStream.Bytes.AsyncIterator
    init(_ stream: ForwardedStream) { iterator = stream.bytes.makeAsyncIterator() }
    func next() async throws -> Data? { try await iterator.next() }
}

extension SSHSession: RouteStreamOpener {
    public func withRouteStream<R: Sendable>(host: String, port: UInt16,
                                _ body: @escaping @Sendable (RouteStream) async throws -> R) async throws -> R {
        try await withStream(host: host, port: port) { stream in
            let cursor = SSHCursor(stream)
            return try await body(RouteStream(receive: { try await cursor.next() }, write: stream.write,
                                       finishWriting: stream.finishWriting))
        }
    }
}

enum RouteError: Error { case closed, refused, oversized, malformed }

func secret() -> String {
    (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
}

func matches(_ candidate: String, _ secret: String) -> Bool {
    let a = Array(candidate.utf8), b = Array(secret.utf8)
    guard a.count == b.count, !b.isEmpty else { return false }
    return timingsafe_bcmp(a, b, b.count) == 0
}

// Used only by the client-to-upstream pump. Surplus bytes belong to the next frame.
final class SocketReader: @unchecked Sendable {
    private var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private var buffer = ByteBuffer()
    init(_ input: NIOAsyncChannelInboundStream<ByteBuffer>) { iterator = input.makeAsyncIterator() }

    func read(_ count: Int) async throws -> [UInt8] {
        while buffer.readableBytes < count {
            guard let bytes = try await iterator.next() else { throw RouteError.closed }
            if buffer.readableBytes == 0 { buffer = bytes }
            else { buffer.discardReadBytes(); buffer.writeImmutableBuffer(bytes) }
        }
        return buffer.readBytes(length: count)!
    }

    func next(maximum: Int = .max) async throws -> Data? {
        if buffer.readableBytes == 0 {
            guard let bytes = try await iterator.next() else { return nil }
            buffer = bytes
        }
        return Data(buffer.readSlice(length: min(maximum, buffer.readableBytes))!.readableBytesView)
    }

    func through(_ suffix: [UInt8], limit: Int) async throws -> [UInt8] {
        var bytes = [UInt8]()
        var matched = 0
        while bytes.count < limit {
            if buffer.readableBytes == 0 {
                guard let chunk = try await iterator.next() else { throw RouteError.closed }
                buffer = chunk
            }
            var consumed = 0
            for byte in buffer.readableBytesView.prefix(limit - bytes.count) {
                consumed += 1
                bytes.append(byte)
                // Both supported delimiters (CRLF and CRLFCRLF) restart on CR.
                matched = byte == suffix[matched] ? matched + 1 : (byte == suffix[0] ? 1 : 0)
                if matched == suffix.count {
                    buffer.moveReaderIndex(forwardBy: consumed)
                    return bytes
                }
            }
            buffer.moveReaderIndex(forwardBy: consumed)
        }
        throw RouteError.oversized
    }
}

struct Peer: Sendable {
    let channel: Channel
    let input: SocketReader
    let output: NIOAsyncChannelOutboundWriter<ByteBuffer>
    func send(_ bytes: Data) async throws { try await output.write(ByteBuffer(bytes: bytes)) }
    func timeout(_ interval: TimeAmount) -> Scheduled<Void> {
        channel.eventLoop.scheduleTask(in: interval) { channel.close(promise: nil) }
    }
}

typealias Socket = NIOAsyncChannel<ByteBuffer, ByteBuffer>

// Admission, stop and late accepts are serialized even across the two listen sockets.
final class Listeners: Sendable {
    private struct State {
        var running = false
        var listeners = [Channel]()
        var unvalidated = [ObjectIdentifier]()
        var clients = [ObjectIdentifier: Channel]()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func bind(port: UInt16, dual: Bool, capacity: Int, pendingCapacity: Int = .max,
              evictOldest: Bool = false, onBound: @Sendable (UInt16) -> Void = { _ in },
              serve: @escaping @Sendable (Peer) async -> Void) async throws -> UInt16 {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let id = ObjectIdentifier(channel)
                    let evicted = try state.withLock { state -> Channel? in
                        guard state.running, state.clients.count < capacity, pendingCapacity > 0
                        else { throw RouteError.refused }
                        var evicted: Channel?
                        if state.unvalidated.count >= pendingCapacity {
                            guard evictOldest else { throw RouteError.refused }
                            evicted = state.clients.removeValue(forKey: state.unvalidated.removeFirst())
                        }
                        state.unvalidated.append(id)
                        state.clients[id] = channel
                        return evicted
                    }
                    evicted?.close(promise: nil)
                    channel.closeFuture.whenComplete { _ in
                        self.state.withLock {
                            $0.clients.removeValue(forKey: ObjectIdentifier(channel))
                            $0.unvalidated.removeAll { $0 == id }
                        }
                    }
                    let socket = try Socket(wrappingChannelSynchronously: channel,
                                            configuration: .init(isOutboundHalfClosureEnabled: true))
                    let work = Task {
                        try? await socket.executeThenClose { input, output in
                            await serve(Peer(channel: channel, input: SocketReader(input), output: output))
                        }
                    }
                    channel.closeFuture.whenComplete { _ in work.cancel() }
                }
            }
        // With no port asked for, IPv4 chooses the number and IPv6 must take the same one. Another
        // socket can hold that number on IPv6 alone, so further numbers are tried before failing.
        var listeners: [Channel] = []
        let attempts = port == 0 && dual ? 32 : 1
        for attempt in 1...attempts {
            let v4 = try await bootstrap.bind(host: "127.0.0.1", port: Int(port)).get()
            guard dual else { listeners = [v4]; break }
            do {
                listeners = [v4, try await bootstrap.bind(host: "::1", port: v4.localAddress!.port!).get()]
                break
            } catch let error as IOError where error.errnoCode == EADDRINUSE && attempt < attempts {
                try? await v4.close()
            } catch {
                try? await v4.close()
                throw error
            }
        }
        let actual = UInt16(listeners[0].localAddress!.port!)
        onBound(actual)
        state.withLock { [listeners] in $0.listeners = listeners; $0.running = true }
        return actual
    }

    func validated(_ client: ObjectIdentifier) -> Bool {
        state.withLock { state in
            state.unvalidated.removeAll { $0 == client }
            return state.clients[client] != nil
        }
    }

    func stop() async {
        let channels = state.withLock { state in
            state.running = false
            defer { state.listeners = [] }
            return state.listeners + Array(state.clients.values)
        }
        for channel in channels { try? await channel.close() }
    }
}

func relay(_ peer: Peer, _ stream: RouteStream) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while let data = try await peer.input.next() { try await stream.write(data) }
            stream.finishWriting()
        }
        group.addTask {
            while let data = try await stream.receive() { try await peer.send(data) }
            peer.output.finish()
        }
        while try await group.next() != nil {}
    }
}
