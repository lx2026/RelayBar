import Foundation
import NIOCore
import NIOSSH

func openChild<T: Sendable>(_ parent: Channel, type: SSHChannelType,
                            initialize: @escaping @Sendable (Channel) throws -> T) async throws -> T {
    try await parent.eventLoop.flatSubmit {
        guard let handler = try? parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
            return parent.eventLoop.makeFailedFuture(TransportError.disconnected)
        }
        let opened = parent.eventLoop.makePromise(of: Channel.self)
        let value = NIOLoopBoundBox<T?>(nil, eventLoop: parent.eventLoop)
        handler.createChannel(opened, channelType: type) { child, _ in
            child.eventLoop.makeCompletedFuture {
                value.value = try initialize(child)
            }
        }
        return opened.futureResult.flatMapThrowing { _ in
            guard let result = value.value else { throw TransportError.disconnected }
            return result
        }
    }.get()
}

private final class StreamCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Data
    typealias OutboundIn = Data
    typealias OutboundOut = SSHChannelData

    private var inputFinished = false

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { inputFinished = true }
        context.fireUserInboundEventTriggered(event)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // After remote EOF both halves are finished. NIOSSH 0.15 rejects a local EOF
        // in this state, but accepts the channel close.
        context.close(mode: mode == .output && inputFinished ? .all : mode, promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.type == .channel, case .byteBuffer(let bytes) = frame.data else {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(wrapInboundOut(Data(bytes.readableBytesView)))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = ByteBuffer(bytes: unwrapOutboundIn(data))
        context.write(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

public struct ForwardedStream: Sendable {
    public struct Bytes: AsyncSequence, Sendable {
        public typealias Element = Data
        let input: NIOAsyncChannelInboundStream<Data>
        public struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: NIOAsyncChannelInboundStream<Data>.AsyncIterator
            public mutating func next() async throws -> Data? {
                do { return try await iterator.next() }
                catch { throw ForwardedStream.failure(error) }
            }
        }
        public func makeAsyncIterator() -> AsyncIterator { .init(iterator: input.makeAsyncIterator()) }
    }

    public let bytes: Bytes
    let output: NIOAsyncChannelOutboundWriter<Data>
    fileprivate static func failure(_ error: Error) -> TransportError {
        if error is CancellationError { return .cancelled }
        return error as? TransportError ?? .disconnected
    }

    public func write(_ data: Data) async throws {
        do { try await output.write(data) }
        catch { throw Self.failure(error) }
    }
    public func finishWriting() { output.finish() }
}

extension SSHSession {
    public func withStream<R: Sendable>(host: String, port: UInt16,
        _ body: @Sendable (ForwardedStream) async throws -> R) async throws -> R {
        guard validHost(host), port > 0 else { throw TransportError.invalidEndpoint }
        let destination = SSHChannelType.DirectTCPIP(targetHost: host, targetPort: Int(port),
            originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let stream: NIOAsyncChannel<Data, Data>
        do {
            stream = try await openChild(try connectedChannel(), type: .directTCPIP(destination)) { child in
                try child.pipeline.syncOperations.addHandler(StreamCodec())
                // SSH child channels implement this option synchronously on their event loop.
                try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                return try NIOAsyncChannel(wrappingChannelSynchronously: child,
                    configuration: .init(isOutboundHalfClosureEnabled: true))
            }
        } catch { throw TransportError.translate(error) }
        return try await stream.executeThenClose { input, output in
            let result = try await body(.init(bytes: .init(input: input), output: output))
            // SSH child close futures can fail. Surface that failure before NIOAsyncChannel
            // performs its final teardown, which assumes a successful close future.
            output.finish()
            stream.channel.close(promise: nil)
            do { try await stream.channel.closeFuture.get() }
            catch { throw ForwardedStream.failure(error) }
            return result
        }
    }
}
