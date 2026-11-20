import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices
import os

// A fresh observer per TCP connection keeps late reads from an old generation isolated.
private final class InboundActivity: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    let latest = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if unwrapInboundIn(data).readableBytes > 0 {
            latest.withLock { $0 = .now }
        }
        context.fireChannelRead(data)
    }
}

public actor SSHSession {
    public nonisolated let states: AsyncStream<SessionState>
    private let events: AsyncStream<SessionState>.Continuation
    private var config: SessionConfiguration
    private var generation = UUID()
    private var inbound = InboundActivity()
    private var channel: Channel?
    private var method: SignInMethod?
    private var connection: Task<SignInMethod, Error>?
    private var subsystemRefusal: ContinuousClock.Instant?
    private var activeWire: SFTPWire?
    private var files: Task<SFTPClient, Error>?
    private var monitor: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    public var isReconnecting: Bool { retry != nil && method == nil }

    public init(_ config: SessionConfiguration) {
        self.config = config
        (states, events) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    deinit {
        monitor?.cancel()
        retry?.cancel()
        channel?.close(promise: nil)
        events.finish()
    }

    @discardableResult
    public func resume() async throws -> SignInMethod {
        guard !Task.isCancelled else { throw TransportError.cancelled }
        if let method { return method }
        if let connection { return try await connection.value }
        retry?.cancel()
        retry = nil
        return try await start()
    }

    private func start(retrying: Bool = false) async throws -> SignInMethod {
        generation = UUID()
        let epoch = generation
        let task = Task {
            defer { if generation == epoch { connection = nil } }
            do { return try await establish(epoch) }
            catch {
                guard generation == epoch else { throw TransportError.cancelled }
                let reason = TransportError.translate(error)
                channel?.close(promise: nil)
                channel = nil
                let retryable = retrying && (reason == .unreachable || reason == .disconnected)
                if !retryable { retry = nil }
                events.yield(retryable ? .interrupted(reason) : .failed(reason))
                throw reason
            }
        }
        connection = task
        return try await task.value
    }

    private func establish(_ epoch: UUID) async throws -> SignInMethod {
        guard epoch == generation else { throw TransportError.cancelled }
        guard validHost(config.host), config.port > 0 else { throw TransportError.invalidEndpoint }
        let activity = InboundActivity()
        inbound = activity
        let settings = config
        let loop = NIOTSEventLoopGroup.singleton.next()
        let ready = loop.makePromise(of: (SignInMethod, HostKey).self)
        let events = self.events
        events.yield(.connecting)
        let parent: Channel
        do {
            parent = try await NIOTSConnectionBootstrap(group: loop)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .connectTimeout(.seconds(15))
                .channelInitializer { channel in
                    // Register before dialing so a concurrent suspend can close a pending connection.
                    let registered = channel.eventLoop.makePromise(of: Void.self)
                    registered.completeWithTask { try await self.register(channel, epoch: epoch) }
                    return registered.futureResult.flatMapThrowing {
                        let auth = Authentication(settings, ready: ready) { state in events.yield(state) }
                        let handler = NIOSSHHandler(role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: auth)),
                            allocator: channel.allocator, inboundChildChannelInitializer: { child, _ in
                                child.eventLoop.makeFailedFuture(TransportError.forwardingProhibited)
                            })
                        try channel.pipeline.syncOperations.addHandlers(activity, handler, auth)
                    }
                }.connect(host: settings.host, port: Int(settings.port)).get()
        } catch {
            ready.fail(error)
            throw error
        }
        guard generation == epoch else {
            parent.close(promise: nil)
            throw TransportError.cancelled
        }
        let (result, accepted) = try await ready.futureResult.get()
        guard epoch == generation else { throw TransportError.cancelled }
        config.pinnedKey = accepted
        method = result
        events.yield(.ready(result))
        parent.closeFuture.whenComplete { [weak self] _ in
            Task { await self?.lost(epoch) }
        }
        startMonitor(epoch, policy: settings.policy)
        return result
    }

    private func register(_ channel: Channel, epoch: UUID) throws {
        guard epoch == generation else { throw TransportError.cancelled }
        self.channel = channel
    }

    private func startMonitor(_ epoch: UUID, policy: SessionPolicy) {
        monitor = Task { [weak self] in
            let idle = max(.milliseconds(1), policy.idle)
            let timeout = max(.milliseconds(1), policy.probeTimeout)
            var lastActivity = ContinuousClock.now
            var deadline = lastActivity + idle
            var misses = 0
            while !Task.isCancelled {
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard let self, await self.generation == epoch else { return }
                if let reply = await self.lastReply(), reply > lastActivity {
                    lastActivity = reply
                    misses = 0
                }
                guard await self.generation == epoch else { return }
                if lastActivity + idle > .now {
                    deadline = lastActivity + idle
                } else if misses >= max(1, policy.missedProbes) {
                    await self.lost(epoch)
                    return
                } else {
                    Task {
                        guard await self.generation == epoch, let client = try? await self.sftp() else { return }
                        _ = try? await client.stat("/")
                    }
                    misses += 1
                    deadline = .now + timeout
                }
            }
        }
    }

    private func lastReply() async -> ContinuousClock.Instant? {
        guard let wire = activeWire else { return subsystemRefusal }
        return try? await wire.channel.eventLoop.submit { wire.lastReply }.get()
    }

    public func suspend() async {
        let old = reset()
        events.yield(.interrupted(.cancelled))
        try? await old?.close()
    }

    private func reset() -> Channel? {
        generation = UUID()
        connection?.cancel()
        connection = nil
        monitor?.cancel()
        monitor = nil
        retry?.cancel()
        retry = nil
        files = nil
        activeWire = nil
        subsystemRefusal = nil
        method = nil
        defer { channel = nil }
        return channel
    }

    /// Validate the active generation after a path transition. A late probe cannot
    /// restart a suspended or replaced session. A path change also wakes pending backoff.
    public func networkPathChanged() async {
        guard connection == nil else { return }
        let epoch = generation
        if method != nil {
            let (results, sender) = AsyncStream<Bool>.makeStream()
            let timeout = max(.milliseconds(1), config.policy.probeTimeout)
            let activity = inbound.latest
            let started = ContinuousClock.now
            let deadline = Task {
                var expires = started + timeout
                while !Task.isCancelled {
                    do { try await Task.sleep(until: expires, clock: .continuous) }
                    catch { return }
                    expires = max(started, activity.withLock { $0 }) + timeout
                    if expires <= .now {
                        sender.yield(false)
                        return
                    }
                }
            }
            let probe = Task {
                do {
                    _ = try await sftp().stat("/")
                    sender.yield(true)
                } catch TransportError.sftpUnavailable, SFTPError.permissionDenied, SFTPError.noSuchFile, SFTPError.status {
                    // A server refusal is also a liveness reply.
                    sender.yield(true)
                } catch {
                    let last = activity.withLock { $0 }
                    sender.yield(last > started && last + timeout > .now)
                }
            }
            var iterator = results.makeAsyncIterator()
            let alive = await iterator.next()
            sender.finish()
            probe.cancel()
            deadline.cancel()
            guard alive == false, !Task.isCancelled else { return }
        } else if retry == nil { return }
        lost(epoch, immediate: true)
    }

    private func lost(_ epoch: UUID, immediate: Bool = false) {
        guard epoch == generation else { return }
        reset()?.close(promise: nil)
        events.yield(.interrupted(.disconnected))
        let policy = config.policy
        retry = Task { [weak self] in
            var upper = policy.firstBackoffUpperBound
            var delay = !immediate
            while !Task.isCancelled {
                do {
                    if delay { try await Task.sleep(for: policy.backoff(upper: upper, fraction: .random(in: 0...1))) }
                    delay = true
                    guard let self else { return }
                    try await self.retryIfNeeded()
                    return
                } catch TransportError.unreachable { upper = policy.nextBackoffUpperBound(upper) }
                catch TransportError.disconnected { upper = policy.nextBackoffUpperBound(upper) }
                catch { return }
            }
        }
    }

    private func retryIfNeeded() async throws {
        guard !Task.isCancelled, connection == nil, method == nil else { return }
        _ = try await start(retrying: true)
    }

    func connectedChannel() throws -> Channel {
        guard method != nil, let channel else { throw TransportError.disconnected }
        return channel
    }

    public func sftp() async throws -> SFTPClient {
        if let activeWire, !activeWire.channel.isActive {
            files = nil
            self.activeWire = nil
        }
        if let files { return try await files.value }
        let parent = try connectedChannel()
        let epoch = generation
        let policy = config.reads
        let timeout = config.replyTimeout
        let task = Task {
            let client = try await SFTPClient.connect(parent, policy: policy, replyTimeout: timeout)
            guard generation == epoch else { throw TransportError.cancelled }
            activeWire = client.wire
            return client
        }
        files = task
        do { return try await task.value }
        catch {
            if generation == epoch {
                files = nil
                // A peer refusing the subsystem has answered the idle probe.
                if error as? TransportError == .sftpUnavailable { subsystemRefusal = .now }
            }
            throw error
        }
    }
}
