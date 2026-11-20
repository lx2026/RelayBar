import CryptoKit
import Foundation
import os
import NIOCore
import NIOSSH
import NIOTransportServices
import Testing
@testable import RelayTransport

private struct Anonymous: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = []
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.success)
    }
}

private struct PeerOptions: Sendable {
    var handleLimit: UInt64 = 1
    var readLimit: UInt32 = 4
    var deferProbeUntilClose = false
    var onForward: (@Sendable (Channel) -> Void)?
    var shortReplies = true
    var entryCount = 1
    var onRead: @Sendable (UInt64, Int) -> Void = { _, _ in }
    var onListPage: @Sendable (Int) -> Void = { _ in }
    var onPath: @Sendable (UInt8, [UInt8]) -> Void = { _, _ in }
    var onClose: @Sendable () -> Void = {}
}

private final class SFTPPeer: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    private var first: ByteBuffer?
    private var handles = Set<UInt8>()
    private var nextHandle: UInt8 = 0
    private var listed = 0
    private var pendingProbe: ByteBuffer?
    private let options: PeerOptions
    private let onProbe: @Sendable () -> Void

    init(_ options: PeerOptions, onProbe: @escaping @Sendable () -> Void) {
        self.options = options
        self.onProbe = onProbe
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let request = event as? SSHChannelRequestEvent.SubsystemRequest, request.subsystem == "sftp" {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(var bytes) = unwrapInboundIn(data).data else { return }
        do {
            _ = try bytes.number(UInt32.self)
            let type = try bytes.number(UInt8.self)
            let id = try bytes.number(UInt32.self)
            var payload = ByteBuffer()
            switch type {
            case 1:
                payload.writeInteger(UInt8(2))
                payload.writeInteger(UInt32(3))
                payload.putString("limits@openssh.com".utf8)
                payload.putString("1".utf8)
            case 200:
                #expect(try bytes.field() == Array("limits@openssh.com".utf8))
                payload.writeInteger(UInt8(201))
                payload.writeInteger(id)
                for limit: UInt64 in [max(4096, UInt64(options.readLimit) + 64), UInt64(options.readLimit), 0, options.handleLimit] { payload.writeInteger(limit) }
            case 3, 11:
                options.onPath(type, try bytes.field())
                #expect(handles.count < Int(options.handleLimit))
                nextHandle += 1
                handles.insert(nextHandle)
                listed = 0
                payload.writeInteger(UInt8(102))
                payload.writeInteger(id)
                payload.putString([nextHandle])
            case 4:
                let handle = try bytes.field()
                #expect(handle.count == 1)
                #expect(handles.remove(handle[0]) != nil)
                if let pendingProbe {
                    send(pendingProbe, context)
                    self.pendingProbe = nil
                }
                options.onClose()
                payload = status(id, 0)
            case 5:
                _ = try bytes.field()
                let offset = try bytes.number(UInt64.self)
                let length = try bytes.number(UInt32.self)
                #expect(length <= options.readLimit)
                payload.writeInteger(UInt8(103))
                payload.writeInteger(id)
                options.onRead(offset, Int(length))
                let size = options.shortReplies ? min(2, Int(length)) : Int(length)
                payload.putString((0..<size).map { UInt8(truncatingIfNeeded: offset + UInt64($0)) })
                if options.shortReplies && length == 4 {
                    guard let saved = first else { first = payload; return }
                    send(payload, context)
                    payload = saved
                    first = nil
                }
            case 17, 7:
                let path = try bytes.field()
                options.onPath(type, path)
                payload.writeInteger(UInt8(105))
                payload.writeInteger(id)
                payload.writeInteger(UInt32(0))
                if path == [47] {
                    onProbe()
                    if options.deferProbeUntilClose { pendingProbe = payload }
                    return
                }
            case 12:
                options.onListPage(listed)
                let count = min(100, options.entryCount - listed)
                if count == 0 { payload = status(id, 1); break }
                payload.writeInteger(UInt8(104))
                payload.writeInteger(id)
                payload.writeInteger(UInt32(count))
                for _ in 0..<count {
                    payload.putString([255])
                    payload.putString([])
                    payload.writeInteger(UInt32(0))
                }
                listed += count
            default: payload = status(id, 8)
            }
            send(payload, context)
        } catch {
            Issue.record("Invalid SFTP request")
            context.close(promise: nil)
        }
    }

    private func status(_ id: UInt32, _ code: UInt32) -> ByteBuffer {
        var reply = ByteBuffer()
        reply.writeInteger(UInt8(101))
        reply.writeInteger(id)
        reply.writeInteger(code)
        reply.putString([])
        reply.putString([])
        return reply
    }

    private func send(_ payload: ByteBuffer, _ context: ChannelHandlerContext) {
        var frame = ByteBuffer()
        frame.writeInteger(UInt32(payload.readableBytes))
        frame.writeImmutableBuffer(payload)
        context.writeAndFlush(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(frame))), promise: nil)
    }
}

private func scriptedServer(_ options: PeerOptions = .init(), onProbe: @escaping @Sendable () -> Void = {}) async throws -> Channel {
    let key = NIOSSHPrivateKey(ed25519Key: .init())
    return try await NIOTSListenerBootstrap(group: .singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let config = SSHServerConfiguration(hostKeys: [key], userAuthDelegate: Anonymous())
                let ssh = NIOSSHHandler(role: .server(config), allocator: channel.allocator) { child, type in
                    child.eventLoop.makeCompletedFuture {
                        if case .directTCPIP = type, let onForward = options.onForward {
                            onForward(child)
                        } else {
                            try child.pipeline.syncOperations.addHandler(SFTPPeer(options, onProbe: onProbe))
                        }
                    }
                }
                try channel.pipeline.syncOperations.addHandler(ssh)
            }
        }.bind(host: "127.0.0.1", port: 0).get()
}

@Test func shortReorderedReadsAndLimits() async throws {
    let closes = OSAllocatedUnfairLock(initialState: 0)
    let paths = OSAllocatedUnfairLock(initialState: [[UInt8]]())
    let server = try await scriptedServer(.init(onPath: { _, path in paths.withLock { $0.append(path) } },
                                                onClose: { closes.withLock { $0 += 1 } }))
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in true }
    config.reads.readAheadBytes = 8
    let session = SSHSession(config)
    _ = try await session.resume()
    let client = try await session.sftp()
    let file = try await client.open("/file")
    await #expect(throws: SFTPError.handleLimit) { _ = try await client.open("/second") }
    let (chunks, output) = AsyncStream<Data>.makeStream()
    try await file.read(range: 0..<8) { output.yield($0) }
    output.finish()
    var data = Data()
    for await chunk in chunks { data.append(chunk) }
    #expect(Array(data) == Array(0..<8))
    let cancelled = Task {
        try await file.read(range: 0..<8) { _ in withUnsafeCurrentTask { $0?.cancel() } }
    }
    await #expect(throws: TransportError.cancelled) { try await cancelled.value }
    #expect(closes.withLock { $0 } == 1)
    let path = Data([47, 255])
    try await client.list(path) { entry in
        #expect(entry.filename == Data([255]))
        #expect(entry.displayName == "�")
    }
    _ = try await client.stat(path)
    _ = try await client.lstat(path)
    try await client.open(path).close()
    #expect(paths.withLock { Array($0.suffix(4)) } == Array(repeating: Array(path), count: 4))
    await session.suspend()
}

@Test func missedIdleProbesInterruptTheSession() async throws {
    let (probes, counter) = AsyncStream<Void>.makeStream()
    let server = try await scriptedServer { counter.yield(()) }
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in true }
    config.policy.idle = .milliseconds(200)
    config.policy.probeTimeout = .milliseconds(100)
    let session = SSHSession(config)
    _ = try await session.resume()
    _ = try await session.sftp()
    let interrupted = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await state in session.states {
                if state == .interrupted(.disconnected) { return true }
            }
            return false
        }
        group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
        let first = await group.next()
        group.cancelAll()
        return first == true
    }
    await session.suspend()
    counter.finish()
    var count = 0
    for await _ in probes { count += 1 }
    #expect(interrupted)
    #expect(count == 2)
}

@Test func incrementalListingAndTruncation() async throws {
    let delivered = OSAllocatedUnfairLock(initialState: 0)
    let server = try await scriptedServer(.init(entryCount: 10_001, onListPage: { sent in
        #expect(delivered.withLock { $0 } == sent)
    }))
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    let session = SSHSession(.init(host: "127.0.0.1", port: port, username: "test") { _ in true })
    _ = try await session.resume()
    let client = try await session.sftp()
    for limit in [10_000, 0, 16, 10_001] {
        delivered.withLock { $0 = 0 }
        let visit: @Sendable (DirectoryEntry) async -> Void = { _ in delivered.withLock { $0 += 1 } }
        let result = limit == 10_000 ? try await client.list("/", visit: visit)
            : try await client.list("/", limit: limit, visit: visit)
        #expect(result.count == limit)
        #expect(delivered.withLock { $0 } == result.count)
        #expect(result.truncated == (limit < 10_001))
    }
    await session.suspend()
}

@Test func slidingReadWindowDuringConsumption() async throws {
    struct Progress { var requested = 0; var consumed = 0; var offsets: [UInt64] = [] }
    let progress = OSAllocatedUnfairLock(initialState: Progress())
    let budget = 12
    let server = try await scriptedServer(.init(handleLimit: 2, shortReplies: false, onRead: { offset, length in
        progress.withLock {
            $0.requested += length
            $0.offsets.append(offset)
            #expect($0.requested - $0.consumed <= budget)
        }
    }))
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in true }
    config.reads.outstanding = 2
    config.reads.readAheadBytes = budget
    let session = SSHSession(config)
    _ = try await session.resume()
    let client = try await session.sftp()
    let bulk = try await client.open("/bulk")
    let interactive = try await client.open("/interactive")
    let bulkRead = Task {
        try await bulk.read(range: 0..<32) { data in
            if data.first == 0 {
                let deadline = ContinuousClock.now + .seconds(2)
                while await client.queuedReadCount < 2 && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
                #expect(await client.queuedReadCount == 2)
            }
            if data.first == 4 {
                let deadline = ContinuousClock.now + .seconds(2)
                while !progress.withLock({ $0.offsets.contains(100) }) && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            progress.withLock { $0.consumed += data.count }
        }
    }
    let deadline = ContinuousClock.now + .seconds(1)
    while progress.withLock({ $0.requested }) < budget && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(progress.withLock { $0.requested } == budget)
    try await interactive.read(range: 100..<104, priority: .interactive) { data in
        progress.withLock { $0.consumed += data.count }
    }
    try await bulkRead.value
    // The first available chunk after the initial three goes to the interactive reader.
    let offsets = progress.withLock { $0.offsets }
    #expect(offsets.prefix(3).sorted() == [0, 4, 8])
    #expect(offsets.dropFirst(3).first == 100)
    try await bulk.close()
    try await interactive.close()
    await session.suspend()
}

@Test func pendingRequestTimesOutOnlyAfterSilence() async throws {
    let seen = OSAllocatedUnfairLock(initialState: false)
    let server = try await scriptedServer { seen.withLock { $0 = true } }
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in true }
    config.replyTimeout = .milliseconds(300)
    let session = SSHSession(config)
    _ = try await session.resume()
    let client = try await session.sftp()
    let missingReply = Task { try await client.stat("/") }
    for _ in 0..<10 {
        _ = try await client.stat("/other")
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(seen.withLock { $0 })
    let start = ContinuousClock.now
    await #expect(throws: TransportError.disconnected) { try await missingReply.value }
    #expect(start.duration(to: .now) >= .milliseconds(120))
    await session.suspend()
}

@Test func openStreamTranslatesReadFailure() async {
    let (input, source) = NIOAsyncChannelInboundStream<Data>.makeTestingStream()
    source.finish(throwing: ChannelError.ioOnClosedChannel)
    await #expect(throws: TransportError.disconnected) {
        for try await _ in ForwardedStream.Bytes(input: input) {}
    }
}

@Test func slowForwardedConsumerBoundsUnreadBytes() async throws {
    let peer = NIOTSEventLoopGroup.singleton.next().makePromise(of: Channel.self)
    let server = try await scriptedServer(.init(onForward: { peer.succeed($0) }))
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    let session = SSHSession(.init(host: "127.0.0.1", port: port, username: "test") { _ in true })
    _ = try await session.resume()
    let total = 48 * 1024 * 1024
    let chunk = 32 * 1024
    struct Transfer { var written = 0; var consumed = 0; var peakUnread = 0 }
    let transfer = OSAllocatedUnfairLock(initialState: Transfer())
    try await session.withStream(host: "localhost", port: 80) { stream in
        let channel = try await peer.futureResult.get()
        async let send: Void = {
            let frame = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(repeating: 42, count: chunk)))
            for _ in 0..<(total / chunk) {
                try await channel.writeAndFlush(frame).get()
                transfer.withLock {
                    $0.written += chunk
                    $0.peakUnread = max($0.peakUnread, $0.written - $0.consumed)
                }
            }
            try await channel.close(mode: .output).get()
        }()
        try await Task.sleep(for: .milliseconds(250))
        for try await data in stream.bytes {
            transfer.withLock { $0.consumed += data.count }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await send
    }
    let result = transfer.withLock { $0 }
    #expect(result.consumed == total)
    // Includes the SSH receive window (8 MiB), in-flight packets and the async reader.
    #expect(result.peakUnread > 0 && result.peakUnread <= 18 * 1024 * 1024)
    await session.suspend()
}

@Test func pathChangeDuringLargeReadPreservesSession() async throws {
    let seen = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    let chunk = 32 * 1024
    let server = try await scriptedServer(.init(readLimit: UInt32(chunk), deferProbeUntilClose: true,
                                                shortReplies: false)) {
        seen.withLock { $0 = .now }
    }
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in true }
    let timeout = Duration.milliseconds(300)
    config.policy.probeTimeout = timeout
    config.reads.readAheadBytes = chunk
    let session = SSHSession(config)
    _ = try await session.resume()
    let client = try await session.sftp()
    let file = try await client.open("/large")
    let total = 2 * 1024 * 1024
    let received = OSAllocatedUnfairLock(initialState: 0)
    async let probe: Void = session.networkPathChanged()
    try await file.read(range: 0..<UInt64(total)) { data in
        received.withLock { $0 += data.count }
        try await Task.sleep(for: .milliseconds(15))
    }
    let start = try #require(seen.withLock { $0 })
    #expect(start.duration(to: .now) > timeout * 2)
    try await file.close() // releases the queued stat reply
    await probe
    #expect(received.withLock { $0 } == total)
    #expect(try await session.sftp() === client)
    await session.suspend()
}

@Test func pathChangeRecoversAfterSilentProbe() async throws {
    let probes = OSAllocatedUnfairLock(initialState: 0)
    let server = try await scriptedServer { probes.withLock { $0 += 1 } }
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in true }
    config.policy.probeTimeout = .milliseconds(200)
    config.policy.minimumBackoff = .seconds(30)
    let session = SSHSession(config)
    _ = try await session.resume()
    _ = try await session.sftp()
    await session.networkPathChanged()
    let recovered = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var lost = false
            for await event in session.states {
                if event == .interrupted(.disconnected) { lost = true }
                if case .ready = event, lost { return true }
            }
            return false
        }
        group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
        let first = await group.next()
        group.cancelAll()
        return first == true
    }
    await session.suspend()
    #expect(recovered)
    #expect(probes.withLock { $0 } == 1)
}
