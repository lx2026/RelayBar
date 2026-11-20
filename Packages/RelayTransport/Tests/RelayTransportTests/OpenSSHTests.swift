#if os(macOS)
import CryptoKit
import Foundation
import NIOCore
import NIOTransportServices
import Testing
@testable import RelayTransport

private actor Collector {
    var bytes = Data()
    var count = 0
    func append(_ chunk: Data) { bytes.append(chunk) }
    func entry() { count += 1 }
}

private actor Ordering: SSHSigner {
    var key: HostKey?
    var prompts = 0
    let signer: SigningKey
    init(_ signer: SigningKey) { self.signer = signer }
    func verify(_ key: HostKey) -> Bool {
        prompts += 1
        self.key = key
        return true
    }
    func signingKey() throws -> SigningKey {
        guard key != nil else { throw TransportError.hostKeyRefused }
        return signer
    }
}

@Test func openSSHKeysAndLifecycle() async throws {
    let fixture = try OpenSSHFixture()
    defer { fixture.cleanup() }
    try await fixture.start()
    for signer in [fixture.ed, fixture.p256] {
        let order = Ordering(signer)
        var config = fixture.configuration()
        config.signer = order
        config.verify = { await order.verify($0) }
        let session = SSHSession(config)
        #expect(try await session.resume() == .publicKey)
        #expect(await order.key?.type == "ssh-ed25519")
        await session.suspend()
        #expect(try await session.resume() == .publicKey)
        await session.suspend()
        #expect(await order.prompts == 1)
        config.pinnedKey = await order.key
        #expect(try await SSHSession(config).resume() == .publicKey)
        #expect(await order.prompts == 1)
        config.pinnedKey = .init(type: "ssh-ed25519", fingerprint: "changed")
        do {
            _ = try await SSHSession(config).resume()
            Issue.record("Accepted a changed key")
        } catch TransportError.hostKeyChanged(let presented) {
            #expect(await order.key == presented)
        }
    }
    let log = try String(contentsOf: fixture.folder.appendingPathComponent("log"), encoding: .utf8)
    let offers = log.components(separatedBy: .newlines).filter { $0.contains("userauth-request for user") }
    #expect(offers.filter { $0.contains("method none") }.count == 6)
    #expect(offers.count == 12)
    for (index, offer) in offers.enumerated() {
        #expect(offer.contains(index.isMultiple(of: 2) ? "method none" : "method publickey"))
    }
    var config = fixture.configuration()
    config.policy.minimumBackoff = .milliseconds(100)
    config.policy.maximumBackoff = .milliseconds(200)
    let session = SSHSession(config)
    _ = try await session.resume()
    // A path change that the live session answers keeps the session and its SFTP client.
    let healthy = try await session.sftp()
    await session.networkPathChanged()
    #expect(await !session.isReconnecting)
    #expect(try await session.sftp() === healthy)
    fixture.stop()
    try await fixture.start()
    let recovered = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var interrupted = false
            for await state in session.states {
                if case .interrupted = state { interrupted = true }
                if interrupted, case .ready = state { return true }
            }
            return false
        }
        group.addTask { try? await Task.sleep(for: .seconds(12)); return false }
        let first = await group.next()
        group.cancelAll()
        return first == true
    }
    #expect(recovered)
    await session.suspend()
}

@Test func openSSHFiles() async throws {
    let fixture = try OpenSSHFixture()
    defer { fixture.cleanup() }
    try await fixture.start()
    let folder = fixture.folder.appendingPathComponent("entries")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    for index in 0..<10_000 {
        try Data().write(to: folder.appendingPathComponent(String(index)))
    }
    let block = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 / 13) })
    let target = fixture.folder.appendingPathComponent("file")
    var expected = Data()
    for index in 0..<1024 {
        let start = expected.count
        expected.append(block)
        expected[start] = UInt8(truncatingIfNeeded: index)
        expected[start + 1] = UInt8(index >> 8)
    }
    try expected.write(to: target)
    let session = SSHSession(fixture.configuration())
    _ = try await session.resume()
    let client = try await session.sftp()
    let list = Collector()
    let listing = try await client.list(folder.path) { _ in await list.entry() }
    #expect(listing.count == 10_000 && !listing.truncated)
    #expect(await list.count == 10_000)
    #expect(try await client.stat(target.path).size == UInt64(expected.count))
    #expect(try await client.lstat(target.path).size == UInt64(expected.count))
    let resolved = try await client.realpath(target.path)
    let originalAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
    let resolvedAttributes = try FileManager.default.attributesOfItem(atPath: resolved)
    #expect(originalAttributes[.systemFileNumber] as? UInt64 == resolvedAttributes[.systemFileNumber] as? UInt64)
    #expect(resolved.hasSuffix("/file"))
    let file = try await client.open(target.path)
    let full = Collector()
    try await file.read { await full.append($0) }
    #expect(await full.bytes == expected)
    let partial = Collector()
    try await file.read(range: 123..<89123, priority: .interactive) { await partial.append($0) }
    #expect(await partial.bytes == expected.subdata(in: 123..<89123))
    let cancelled = Task {
        try await file.read { _ in withUnsafeCurrentTask { $0?.cancel() } }
    }
    await #expect(throws: TransportError.cancelled) { try await cancelled.value }
    await #expect(throws: SFTPError.closed) { try await file.read { _ in } }
    await #expect(throws: SFTPError.noSuchFile) { _ = try await client.open(target.path + "-missing") }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: target.path)
    await #expect(throws: SFTPError.permissionDenied) { _ = try await client.open(target.path) }
    await session.suspend()
}

private actor OpenStreamBarrier {
    private var count = 0
    private let opened: EventLoopPromise<Void>
    init(on loop: EventLoop) {
        opened = loop.makePromise()
        let timeout = loop.scheduleTask(in: .seconds(15)) { [opened] in opened.fail(TransportError.unreachable) }
        opened.futureResult.whenComplete { _ in timeout.cancel() }
    }

    func waitForAllStreams() async throws {
        count += 1
        if count == 50 { opened.succeed(()) }
        try await opened.futureResult.get()
    }
}

private final class HTTPResponder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var request = ByteBuffer()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        request.writeImmutableBuffer(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            #expect(String(buffer: request) == "GET / HTTP/1.0\r\n\r\n")
            let bytes = ByteBuffer(string: "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK")
            context.writeAndFlush(wrapOutboundOut(bytes)).whenComplete { [channel = context.channel] _ in
                channel.close(promise: nil)
            }
        }
    }
}

@Test func openSSHStreams() async throws {
    let fixture = try OpenSSHFixture()
    defer { fixture.cleanup() }
    try await fixture.start()
    let http = try await NIOTSListenerBootstrap(group: .singleton)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(HTTPResponder()) }
        }.bind(host: "127.0.0.1", port: 0).get()
    defer { http.close(promise: nil) }
    let port = UInt16(try #require(http.localAddress?.port))
    let session = SSHSession(fixture.configuration())
    _ = try await session.resume()
    let barrier = OpenStreamBarrier(on: http.eventLoop)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<50 {
            group.addTask {
                try await session.withStream(host: "127.0.0.1", port: port) { stream in
                    try await barrier.waitForAllStreams()
                    try await stream.write(Data("GET / HTTP/1.0\r\n\r\n".utf8))
                    stream.finishWriting()
                    await #expect(throws: TransportError.disconnected) { try await stream.write(Data([0])) }
                    var reply = Data()
                    for try await bytes in stream.bytes { reply.append(bytes) }
                    #expect(String(decoding: reply, as: UTF8.self).hasSuffix("\r\n\r\nOK"))
                }
            }
        }
        try await group.waitForAll()
    }
    await #expect(throws: TransportError.forwardingProhibited) {
        try await session.withStream(host: "localhost", port: port) { _ in }
    }
    let closed = try loopbackPort()
    await #expect(throws: TransportError.connectionRefused) {
        try await session.withStream(host: "127.0.0.1", port: closed) { _ in }
    }
    await session.suspend()
}

@Test func hostKeyRefusal() async throws {
    let fixture = try OpenSSHFixture()
    defer { fixture.cleanup() }
    try await fixture.start()
    var config = fixture.configuration()
    config.verify = { _ in false }
    let session = SSHSession(config)
    await #expect(throws: TransportError.hostKeyRefused) { try await session.resume() }
}

@Test func algorithmMismatch() async throws {
    let fixture = try OpenSSHFixture(ciphers: "aes128-ctr")
    defer { fixture.cleanup() }
    try await fixture.start()
    let session = SSHSession(fixture.configuration())
    do {
        _ = try await session.resume()
        Issue.record("Unexpected cipher negotiation")
    } catch TransportError.algorithmMismatch(let supported) {
        #expect(supported.contains("aes256-gcm@openssh.com"))
        #expect(!supported.contains("aes128-ctr"))
    }
}

@Test func guardedRemovalAndTail() async throws {
    let fixture = try OpenSSHFixture()
    defer { fixture.cleanup() }
    try await fixture.start()
    let session = SSHSession(fixture.configuration())
    try await session.resume()
    let client = try await session.sftp()
    let url = fixture.folder.appendingPathComponent("tail")
    let path = url.path
    try Data([1, 2]).write(to: url)
    let fingerprint = try #require(SFTPFileFingerprint(path: path, attributes: try await client.lstat(path)))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: path)
    await #expect(throws: SFTPError.fileChanged) { try await client.remove(path, matching: fingerprint) }
    let first = try await client.tail(path, offset: 1)
    #expect(first.bytes == Data([2]))
    let writer = try FileHandle(forWritingTo: url)
    try writer.seekToEnd()
    try writer.write(contentsOf: Data([3]))
    try writer.close()
    let append = try await client.tail(path, offset: 2, identity: first.identity)
    #expect(append.bytes == Data([3]) && !append.reset)
    await #expect(throws: SFTPError.fileChanged) { try await client.remove(path, matching: fingerprint) }
    try Data([4, 5, 6, 7]).write(to: url, options: .atomic)
    #expect(try await client.tail(path, offset: 3, identity: append.identity).reset)
    try Data([8]).write(to: url)
    #expect(try await client.tail(path, offset: 3, identity: append.identity).reset)
    let link = fixture.folder.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    await #expect(throws: SFTPError.symbolicLink) { try await client.remove(link.path, matching: fingerprint) }
    await #expect(throws: SFTPError.isDirectory) { try await client.remove(fixture.folder.path, matching: fingerprint) }
    let current = try #require(SFTPFileFingerprint(path: path, attributes: try await client.lstat(path)))
    try await client.remove(Data(path.utf8), matching: current)
    await #expect(throws: SFTPError.noSuchFile) { try await client.remove(path, matching: current) }
    await session.suspend()
}
#endif
