import NIOCore
import NIOSSH

// Mutable state belongs to the child event loop. request() is the cross-task entry point.
final class SFTPWire: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let channel: Channel
    let version: EventLoopPromise<Bool>
    private var buffer = ByteBuffer()
    private var nextID: UInt32 = 0
    private var pending: [UInt32: EventLoopPromise<Packet>] = [:]
    private var negotiated = false
    private(set) var lastReply = ContinuousClock.now
    private static let maximumPacket = 1024 * 1024

    private var silenceTimer: Scheduled<Void>?
    private let replyTimeout: TimeAmount

    init(_ channel: Channel, replyTimeout: TimeAmount = .seconds(30)) {
        self.replyTimeout = replyTimeout
        self.channel = channel
        version = channel.eventLoop.makePromise()
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(30)) {
            self.fail(TransportError.disconnected)
            self.channel.close(promise: nil)
        }
        version.futureResult.whenComplete { _ in timeout.cancel() }
        context.triggerUserOutboundEvent(request, promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            var initPacket = ByteBuffer()
            initPacket.writeInteger(UInt32(5))
            initPacket.writeInteger(UInt8(1))
            initPacket.writeInteger(UInt32(3))
            send(initPacket)
        } else if event is ChannelFailureEvent {
            errorCaught(context: context, error: TransportError.sftpUnavailable)
        }
    }

    private func send(_ buffer: ByteBuffer) {
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).whenFailure { _ in
            self.channel.close(promise: nil)
        }
    }

    func request(_ type: UInt8, _ body: ByteBuffer) async throws -> Packet {
        try await channel.eventLoop.flatSubmit {
            guard self.channel.isActive else { return self.channel.eventLoop.makeFailedFuture(SFTPError.closed) }
            self.nextID &+= 1
            let id = self.nextID
            let promise = self.channel.eventLoop.makePromise(of: Packet.self)
            self.pending[id] = promise
            if self.silenceTimer == nil { self.armSilenceTimer() }
            var packet = ByteBuffer()
            packet.writeInteger(UInt32(5 + body.readableBytes))
            packet.writeInteger(type)
            packet.writeInteger(id)
            packet.writeImmutableBuffer(body)
            self.send(packet)
            return promise.futureResult
        }.get()
    }

    private func armSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = pending.isEmpty ? nil : channel.eventLoop.scheduleTask(in: replyTimeout) {
            self.fail(TransportError.disconnected)
            self.channel.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.type == .channel, case .byteBuffer(var bytes) = frame.data else { return }
        buffer.writeBuffer(&bytes)
        do {
            while let size = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) {
                guard size >= 5, size <= Self.maximumPacket else { throw SFTPError.malformedPacket }
                guard buffer.readableBytes >= Int(size) + 4 else { break }
                buffer.moveReaderIndex(forwardBy: 4)
                var payload = buffer.readSlice(length: Int(size))!
                let type = try payload.number(UInt8.self)
                let id = try payload.number(UInt32.self)
                if !negotiated {
                    guard type == 2, id == 3 else { throw TransportError.sftpUnavailable }
                    var limits = false
                    while payload.readableBytes > 0 {
                        let name = try payload.field()
                        let value = try payload.field()
                        if name.elementsEqual("limits@openssh.com".utf8), value == [49] { limits = true }
                    }
                    negotiated = true
                    version.succeed(limits)
                } else {
                    guard let promise = pending.removeValue(forKey: id) else { throw SFTPError.malformedPacket }
                    armSilenceTimer()
                    promise.succeed(Packet(type: type, body: payload))
                }
                lastReply = .now
            }
            buffer.discardReadBytes()
        } catch { errorCaught(context: context, error: error) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        fail(TransportError.sftpUnavailable)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(SFTPError.closed)
        context.fireChannelInactive()
    }

    private func fail(_ error: Error) {
        silenceTimer?.cancel()
        silenceTimer = nil
        version.fail(error)
        for promise in pending.values { promise.fail(error) }
        pending.removeAll()
    }
}
