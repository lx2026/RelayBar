import CryptoKit
import Foundation
import NIOCore
import NIOSSH

public enum ReadPriority: Sendable { case bulk, interactive }

public actor SFTPClient {
    nonisolated let wire: SFTPWire
    /// The largest single READ after applying the server's negotiated packet and read limits.
    public nonisolated var maximumReadLength: Int { chunk }
    private let chunk: Int
    private let handleLimit: UInt64
    private let packetLimit: UInt64
    private var requestsAvailable: Int
    private var chunksAvailable: Int
    private var handles = 0
    private struct Waiter {
        let id: UUID
        let priority: ReadPriority
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    var queuedReadCount: Int { waiters.count }

    private init(_ wire: SFTPWire, policy: ReadPolicy, maxRead: UInt64, packet: UInt64, handles: UInt64) throws {
        self.wire = wire
        let budget = max(1, policy.readAheadBytes)
        guard packet == 0 || packet > 13 else { throw SFTPError.malformedPacket }
        packetLimit = packet == 0 ? .max : packet
        chunk = min(max(1, policy.requestBytes), 256 * 1024, budget,
                    maxRead == 0 ? .max : Int(clamping: maxRead), Int(clamping: packetLimit - 13))
        requestsAvailable = min(max(1, policy.outstanding), 1024)
        chunksAvailable = budget / chunk
        handleLimit = handles == 0 ? .max : handles
    }

    static func connect(_ parent: Channel, policy: ReadPolicy, replyTimeout: TimeAmount) async throws -> SFTPClient {
        let wire: SFTPWire
        do {
            wire = try await openChild(parent, type: .session) { child in
                let wire = SFTPWire(child, replyTimeout: replyTimeout)
                try child.pipeline.syncOperations.addHandler(wire)
                return wire
            }
        } catch let error as NIOSSHError where error.type == .channelSetupRejected {
            throw TransportError.sftpUnavailable
        } catch { throw TransportError.translate(error) }
        do {
            var packet: UInt64 = 0, read: UInt64 = 0, handles: UInt64 = 0
            if try await wire.version.futureResult.get() {
                var query = ByteBuffer()
                query.putString("limits@openssh.com".utf8)
                var limits = try await wire.request(200, query).expect(201)
                packet = try limits.number()
                read = try limits.number()
                _ = try limits.number(UInt64.self)
                handles = try limits.number()
            }
            return try SFTPClient(wire, policy: policy, maxRead: read, packet: packet, handles: handles)
        } catch {
            wire.channel.close(promise: nil)
            throw error
        }
    }

    private func request(_ type: UInt8, _ body: ByteBuffer, expecting: UInt8) async throws -> ByteBuffer {
        guard UInt64(body.readableBytes + 9) <= packetLimit else { throw SFTPError.malformedPacket }
        return try await wire.request(type, body).expect(expecting)
    }

    public func realpath(_ path: String) async throws -> String {
        var result = try await request(16, pathPacket(path), expecting: 104)
        guard try result.number(UInt32.self) == 1,
              let name = String(bytes: try result.field(), encoding: .utf8) else { throw SFTPError.invalidPath }
        _ = try pathPacket(name)
        return name
    }

    /// The folder the server starts this session in, normally the account's home.
    public func home() async throws -> String {
        var bytes = ByteBuffer()
        bytes.putString(Data(".".utf8))
        var result = try await request(16, bytes, expecting: 104)
        guard try result.number(UInt32.self) == 1,
              let name = String(bytes: try result.field(), encoding: .utf8) else { throw SFTPError.invalidPath }
        _ = try pathPacket(name)
        return name
    }

    public func stat(_ path: String) async throws -> FileAttributes { try await stat(Data(path.utf8)) }
    public func stat(_ path: Data) async throws -> FileAttributes { try await attributes(path, type: 17) }
    public func lstat(_ path: String) async throws -> FileAttributes { try await lstat(Data(path.utf8)) }
    public func lstat(_ path: Data) async throws -> FileAttributes { try await attributes(path, type: 7) }

    private func attributes(_ path: Data, type: UInt8) async throws -> FileAttributes {
        var result = try await request(type, pathPacket(path), expecting: 105)
        return try FileAttributes(&result)
    }

    private func openHandle(_ path: Data, directory: Bool) async throws -> ByteBuffer {
        var query = try pathPacket(path)
        guard UInt64(handles) < handleLimit else { throw SFTPError.handleLimit }
        handles += 1
        do {
            if !directory {
                query.writeInteger(UInt32(1)) // SSH_FXF_READ
                query.writeInteger(UInt32(0)) // attributes
            }
            var reply = try await request(directory ? 11 : 3, query, expecting: 102)
            let handle = try reply.field()
            guard handle.count <= 256 else {
                wire.channel.close(promise: nil)
                throw SFTPError.malformedPacket
            }
            var encoded = ByteBuffer()
            encoded.putString(handle)
            return encoded
        } catch {
            handles -= 1
            throw error
        }
    }

    fileprivate func close(_ handle: ByteBuffer) async throws {
        defer { handles -= 1 }
        do { _ = try await request(4, handle, expecting: 101) }
        catch {
            // Retire the subsystem if the peer cannot confirm release of its handle.
            wire.channel.close(promise: nil)
            throw error
        }
    }

    public func open(_ path: String) async throws -> SFTPFile {
        try await open(Data(path.utf8))
    }

    public func open(_ path: Data) async throws -> SFTPFile {
        let handle = try await openHandle(path, directory: false)
        if Task.isCancelled {
            try? await close(handle)
            throw TransportError.cancelled
        }
        return SFTPFile(client: self, handle: handle)
    }

    @discardableResult
    public func list(_ path: String,
                     visit: @Sendable (DirectoryEntry) async throws -> Void)
        async throws -> (count: Int, truncated: Bool) {
        try await list(Data(path.utf8), limit: 10_000, visit: visit)
    }

    @discardableResult
    public func list(_ path: String, limit: Int,
                     visit: @Sendable (DirectoryEntry) async throws -> Void)
        async throws -> (count: Int, truncated: Bool) {
        try await list(Data(path.utf8), limit: limit, visit: visit)
    }

    @discardableResult
    public func list(_ path: Data, limit: Int = 10_000,
                     visit: @Sendable (DirectoryEntry) async throws -> Void)
        async throws -> (count: Int, truncated: Bool) {
        let handle = try await openHandle(path, directory: true)
        var delivered = 0
        var truncated = false
        do {
            pages: while true {
                try Task.checkCancellation()
                var packet: ByteBuffer
                do { packet = try await request(12, handle, expecting: 104) }
                catch SFTPError.endOfFile { break }
                let count = try packet.number(UInt32.self)
                guard count > 0 else { throw SFTPError.malformedPacket }
                for _ in 0..<count {
                    let name = try packet.field()
                    _ = try packet.field()
                    let attributes = try FileAttributes(&packet)
                    let display = String(decoding: name, as: UTF8.self)
                    guard !name.isEmpty, name.count <= 4096, !display.contains("/"),
                          display != ".", display != "..", display.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
                    try Task.checkCancellation()
                    guard delivered < limit else {
                        truncated = true
                        break pages
                    }
                    try await visit(.init(filename: Data(name), attributes: attributes))
                    delivered += 1
                }
            }
        } catch {
            try? await close(handle)
            if Task.isCancelled { throw TransportError.cancelled }
            throw error
        }
        try await close(handle)
        return (delivered, truncated)
    }

    fileprivate func reserve(priority: ReadPriority) async throws {
        try Task.checkCancellation()
        if requestsAvailable > 0 && chunksAvailable > 0 {
            requestsAvailable -= 1
            chunksAvailable -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                waiters.append(Waiter(id: id, priority: priority, continuation: $0))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: TransportError.cancelled)
        }
    }

    fileprivate func release(requests: Int = 0, chunks: Int = 0) {
        requestsAvailable += requests
        chunksAvailable += chunks
        while !waiters.isEmpty, requestsAvailable > 0, chunksAvailable > 0 {
            let index = waiters.firstIndex { $0.priority == .interactive } ?? 0
            let waiter = waiters.remove(at: index)
            requestsAvailable -= 1
            chunksAvailable -= 1
            waiter.continuation.resume()
        }
    }

    fileprivate func block(_ handle: ByteBuffer, offset: UInt64, length: Int) async throws -> Data {
        var data = Data()
        while data.count < length {
            try Task.checkCancellation()
            var query = handle
            query.writeInteger(offset + UInt64(data.count))
            query.writeInteger(UInt32(length - data.count))
            do {
                var reply = try await request(5, query, expecting: 103)
                let bytes = try reply.field()
                guard !bytes.isEmpty, bytes.count <= length - data.count else { throw SFTPError.malformedPacket }
                data.append(contentsOf: bytes)
            } catch SFTPError.endOfFile { break }
        }
        return data
    }

    fileprivate func read(_ handle: ByteBuffer, range: Range<UInt64>, priority: ReadPriority,
                          consume: @Sendable (Data) async throws -> Void) async throws {
        let pipeline = ReadPipeline(client: self, handle: handle, chunk: chunk)
        try await pipeline.read(range, priority: priority, consume: consume)
    }
}

// Each stream element owns a reserved chunk. Publish futures in offset order so that
// a slow reply delays delivery without blocking later requests or their replies.
private actor ReadPipeline {
    let client: SFTPClient
    let handle: ByteBuffer
    let chunk: Int
    var reserved = 0
    typealias Block = (reply: EventLoopFuture<Data>, length: Int)

    init(client: SFTPClient, handle: ByteBuffer, chunk: Int) {
        self.client = client
        self.handle = handle
        self.chunk = chunk
    }

    private func produce(_ range: Range<UInt64>, priority: ReadPriority,
                         into output: AsyncThrowingStream<Block, Error>.Continuation) async {
        await withDiscardingTaskGroup { workers in
            do {
                var offset = range.lowerBound
                while offset < range.upperBound {
                    try await client.reserve(priority: priority)
                    reserved += 1
                    let length = Int(min(UInt64(chunk), range.upperBound - offset))
                    let reply = client.wire.channel.eventLoop.makePromise(of: Data.self)
                    workers.addTask { [client, handle, offset] in
                        do { reply.succeed(try await client.block(handle, offset: offset, length: length)) }
                        catch { reply.fail(error) }
                        await client.release(requests: 1)
                    }
                    output.yield((reply.futureResult, length))
                    offset += UInt64(length)
                }
                output.finish()
            } catch { output.finish(throwing: error) }
        }
    }

    func read(_ range: Range<UInt64>, priority: ReadPriority,
              consume: @Sendable (Data) async throws -> Void) async throws {
        let (blocks, output) = AsyncThrowingStream<Block, Error>.makeStream()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await self.produce(range, priority: priority, into: output) }
                defer { group.cancelAll() }
                for try await block in blocks {
                    let bytes = try await block.reply.get()
                    try Task.checkCancellation()
                    if !bytes.isEmpty { try await consume(bytes) }
                    try Task.checkCancellation()
                    reserved -= 1
                    await client.release(chunks: 1)
                    if bytes.count < block.length { break }
                }
                try Task.checkCancellation()
            }
        } catch {
            await client.release(chunks: reserved)
            throw error
        }
        await client.release(chunks: reserved)
    }
}

public actor SFTPFile {
    private let client: SFTPClient
    private var reading = false
    private var handle: ByteBuffer?
    fileprivate init(client: SFTPClient, handle: ByteBuffer) {
        self.client = client
        self.handle = handle
    }

    deinit {
        if let handle {
            let client = client
            Task { try? await client.close(handle) }
        }
    }

    public func close() async throws {
        guard !reading else { throw SFTPError.handleInUse }
        guard let handle else { return }
        self.handle = nil
        try await client.close(handle)
    }

    public func read(range: Range<UInt64> = 0..<UInt64.max, priority: ReadPriority = .bulk,
                     consume: @Sendable (Data) async throws -> Void) async throws {
        guard let handle else { throw SFTPError.closed }
        guard !reading else { throw SFTPError.handleInUse }
        reading = true
        defer { reading = false }
        do {
            try await client.read(handle, range: range, priority: priority, consume: consume)
            try Task.checkCancellation()
        }
        catch {
            if Task.isCancelled {
                reading = false
                try? await close()
                throw TransportError.cancelled
            }
            throw error
        }
    }
}

/// SFTP v3 has no inode field. Verify continuity using the bytes immediately before the cursor.
public struct SFTPTailIdentity: Sendable {
    fileprivate let path: Data
    fileprivate let offset: UInt64
    fileprivate let observedSize: UInt64
    fileprivate let digest: SHA256.Digest
}

public struct SFTPTailResult: Sendable {
    public let bytes: Data
    public let reset: Bool
    public let identity: SFTPTailIdentity
    public var nextOffset: UInt64 { identity.offset }
}

extension SFTPClient {
    public func remove(_ path: String, matching fingerprint: SFTPFileFingerprint) async throws {
        try await remove(Data(path.utf8), matching: fingerprint)
    }

    public func remove(_ path: Data, matching fingerprint: SFTPFileFingerprint) async throws {
        let attributes = try await lstat(path)
        switch attributes.permissions.map({ $0 & 0o170000 }) {
        case 0o040000: throw SFTPError.isDirectory
        case 0o120000: throw SFTPError.symbolicLink
        case 0o100000: break
        default: throw SFTPError.fileChanged
        }
        guard path == fingerprint.path, attributes.size == fingerprint.size,
              attributes.modificationTime == fingerprint.modificationTime else { throw SFTPError.fileChanged }
        try Task.checkCancellation()
        _ = try await request(13, pathPacket(path), expecting: 101)
    }

    public func tail(_ path: String, offset: UInt64, identity: SFTPTailIdentity? = nil) async throws -> SFTPTailResult {
        try await tail(Data(path.utf8), offset: offset, identity: identity)
    }

    public func tail(_ path: Data, offset: UInt64, identity: SFTPTailIdentity? = nil) async throws -> SFTPTailResult {
        let handle = try await openHandle(path, directory: false)
        let result: SFTPTailResult
        do {
            var packet = try await request(8, handle, expecting: 105) // FSTAT the same handle used for READ.
            let attrs = try FileAttributes(&packet)
            guard let size = attrs.size, attrs.permissions.map({ $0 & 0o170000 }) == 0o100000 else {
                throw SFTPError.malformedPacket
            }
            let anchorSize = Int(min(offset, 4096))
            var anchor = Data()
            var reset = size < offset || size < (identity?.observedSize ?? 0)
            if !reset {
                anchor = try await tailBytes(handle, offset: offset - UInt64(anchorSize), count: anchorSize)
                if let identity {
                    reset = identity.path != path || identity.offset != offset || identity.digest != SHA256.hash(data: anchor)
                }
                reset = reset || anchor.count != anchorSize
            }
            var bytes = Data()
            if !reset {
                let count = Int(min(size - offset, 2 * 1024 * 1024))
                bytes = try await tailBytes(handle, offset: offset, count: count)
                reset = bytes.count != count
            }
            if reset {
                bytes = Data()
                anchor = Data()
            }
            anchor.append(bytes.suffix(4096))
            let next = SFTPTailIdentity(path: path, offset: reset ? 0 : offset + UInt64(bytes.count),
                                        observedSize: reset ? 0 : size, digest: SHA256.hash(data: anchor.suffix(4096)))
            result = SFTPTailResult(bytes: bytes, reset: reset, identity: next)
        } catch {
            try? await close(handle)
            throw error
        }
        try await close(handle)
        return result
    }

    private func tailBytes(_ handle: ByteBuffer, offset: UInt64, count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            let length = min(chunk, count - bytes.count)
            try await reserve(priority: .bulk)
            defer { release(requests: 1, chunks: 1) }
            let part = try await block(handle, offset: offset + UInt64(bytes.count), length: length)
            bytes.append(part)
            if part.count < length { break }
        }
        return bytes
    }
}
