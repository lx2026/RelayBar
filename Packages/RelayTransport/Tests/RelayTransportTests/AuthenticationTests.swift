import CryptoKit
import Foundation
import os
import NIOCore
import NIOSSH
import NIOTransportServices
import Testing
@testable import RelayTransport

private struct ServerAuth: NIOSSHServerUserAuthenticationDelegate {
    let onOffer: @Sendable (SignInMethod) -> Void
    let allowNone: Bool
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        switch request.request {
        case .none: onOffer(.none)
        case .password: onOffer(.password)
        default: Issue.record("Unexpected sign-in method")
        }
        switch request.request {
        case .none where allowNone: responsePromise.succeed(.success)
        case .password(let value) where value.password == "test secret": responsePromise.succeed(.success)
        default: responsePromise.succeed(.failure)
        }
    }
}

// Lets a test drop every live connection and turn new ones away until it reopens.
private actor Gate {
    private var accepting = true
    private var connections: [Channel] = []

    func admit(_ channel: Channel) -> Bool {
        if accepting { connections.append(channel) }
        return accepting
    }

    func drop() {
        accepting = false
        for channel in connections { channel.close(promise: nil) }
        connections = []
    }

    func reopen() { accepting = true }
}

private func sshServer(allowNone: Bool, port: Int = 0, gate: Gate? = nil,
                       replacementKey: (@Sendable () -> NIOSSHPrivateKey)? = nil,
                       onOffer: @escaping @Sendable (SignInMethod) -> Void = { _ in }) async throws -> Channel {
    // One key per server, so a reconnect meets the key the client pinned.
    let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
    return try await NIOTSListenerBootstrap(group: .singleton)
        .childChannelInitializer { channel in
            let admitted = channel.eventLoop.makePromise(of: Bool.self)
            admitted.completeWithTask { await gate?.admit(channel) ?? true }
            return admitted.futureResult.flatMapThrowing { admit in
                guard admit else {
                    channel.close(promise: nil)
                    return
                }
                let config = SSHServerConfiguration(hostKeys: [replacementKey?() ?? hostKey],
                    userAuthDelegate: ServerAuth(onOffer: onOffer, allowNone: allowNone),
                    banner: .init(message: "Test banner", languageTag: "en"))
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .server(config),
                    allocator: channel.allocator, inboundChildChannelInitializer: { child, _ in
                        child.eventLoop.makeFailedFuture(TransportError.sftpUnavailable)
                    }))
            }
        }.bind(host: "127.0.0.1", port: port).get()
}

@Test(arguments: [0, 1, 2])
func authentication(_ scenario: Int) async throws {
    let offers = OSAllocatedUnfairLock(initialState: [SignInMethod]())
    let server = try await sshServer(allowNone: scenario == 0, onOffer: { offer in
        offers.withLock { $0.append(offer) }
    })
    defer { server.close(promise: nil) }
    let port = try #require(server.localAddress?.port)
    var config = SessionConfiguration(host: "127.0.0.1", port: UInt16(port), username: "test") { _ in true }
    let (banners, continuation) = AsyncStream<String>.makeStream()
    config.banner = { continuation.yield($0) }
    config.password = { scenario == 1 ? "test secret" : "incorrect" }
    let session = SSHSession(config)
    do {
        let result = try await session.resume()
        #expect(scenario < 2)
        #expect(result == (scenario == 0 ? .none : .password))
        await #expect(throws: TransportError.sftpUnavailable) { try await session.sftp() }
    } catch {
        #expect(scenario == 2)
        #expect(error as? TransportError == .signInRefused([.password]))
    }
    await session.suspend()
    #expect(offers.withLock { $0 } == (scenario == 0 ? [.none] : [.none, .password]))
    continuation.finish()
    var iterator = banners.makeAsyncIterator()
    if scenario != 2 { #expect(await iterator.next() == "Test banner") }
}

private struct PromptDismissed: Error {}

@Test func failingCredentialProviderRefusesSignIn() async throws {
    let server = try await sshServer(allowNone: false)
    defer { server.close(promise: nil) }
    let port = try #require(server.localAddress?.port)
    var config = SessionConfiguration(host: "127.0.0.1", port: UInt16(port), username: "test") { _ in true }
    config.password = { throw PromptDismissed() }
    let session = SSHSession(config)
    await #expect(throws: TransportError.signInRefused([.password])) { try await session.resume() }
}

@Test func failedReconnectAttemptsAreInterruptions() async throws {
    let gate = Gate()
    let server = try await sshServer(allowNone: true, gate: gate)
    defer { server.close(promise: nil) }
    let port = try #require(server.localAddress?.port)
    var config = SessionConfiguration(host: "127.0.0.1", port: UInt16(port), username: "test") { _ in true }
    config.policy.minimumBackoff = .milliseconds(20)
    config.policy.maximumBackoff = .milliseconds(40)
    let session = SSHSession(config)
    #expect(try await session.resume() == .none)
    await gate.drop()
    // Suspending ends the state loop below if the session never recovers.
    let watchdog = Task {
        try await Task.sleep(for: .seconds(10))
        await session.suspend()
    }
    var interruptions = 0
    var failed = false
    var recovered = false
    loop: for await state in session.states {
        switch state {
        case .interrupted(.cancelled): break loop
        case .interrupted:
            interruptions += 1
            if interruptions == 3 { await gate.reopen() }
        case .failed: failed = true
        case .ready where interruptions > 0:
            recovered = true
            break loop
        default: break
        }
    }
    watchdog.cancel()
    await session.suspend()
    #expect(!failed)
    #expect(interruptions >= 3)
    #expect(recovered)
}

#if os(macOS)
@Test func refusedConnectionCanBeResumed() async throws {
    let port = try loopbackPort()
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in
        try? await Task.sleep(for: .milliseconds(700))
        return true
    }
    config.handshakeTimeout = .milliseconds(400)
    let session = SSHSession(config)
    let start = ContinuousClock.now
    await #expect(throws: TransportError.unreachable) { try await session.resume() }
    #expect(start.duration(to: .now) < .seconds(3))
    let server = try await sshServer(allowNone: true, port: Int(port))
    defer { server.close(promise: nil) }
    #expect(try await session.resume() == .none)
    await session.suspend()
}
#endif

@Test func firstBackoffHasJitter() {
    let policy = SessionPolicy()
    let upper = policy.firstBackoffUpperBound
    #expect(policy.backoff(upper: upper, fraction: 0) == .seconds(1))
    #expect(policy.backoff(upper: upper, fraction: 1) == .seconds(2))
    #expect(policy.nextBackoffUpperBound(.seconds(20)) == .seconds(30))
}

@Test func changedHostKeyStopsReconnect() async throws {
    let gate = Gate()
    let first = NIOSSHPrivateKey(ed25519Key: .init())
    let replacement = NIOSSHPrivateKey(ed25519Key: .init())
    let attempts = OSAllocatedUnfairLock(initialState: 0)
    let server = try await sshServer(allowNone: true, gate: gate, replacementKey: {
        attempts.withLock { count in
            count += 1
            return count == 1 ? first : replacement
        }
    })
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in
        Issue.record("Prompted for a pinned host")
        return false
    }
    config.pinnedKey = try HostKey(first.publicKey)
    config.policy.minimumBackoff = .milliseconds(50)
    config.policy.maximumBackoff = .milliseconds(80)
    let session = SSHSession(config)
    _ = try await session.resume()
    await gate.drop()
    await gate.reopen()
    let changed = try HostKey(replacement.publicKey)
    let failed = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await state in session.states {
                if case .failed(let reason) = state { return reason == .hostKeyChanged(changed) }
            }
            return false
        }
        group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
        let result = await group.next()
        group.cancelAll()
        return result == true
    }
    #expect(failed)
    try await Task.sleep(for: .milliseconds(250))
    #expect(attempts.withLock { $0 } == 2)
    await session.suspend()
}

@Test func handshakeDeadlineResumesAfterTrust() async throws {
    let server = try await sshServer(allowNone: false)
    defer { server.close(promise: nil) }
    let port = UInt16(try #require(server.localAddress?.port))
    var config = SessionConfiguration(host: "127.0.0.1", port: port, username: "test") { _ in
        try? await Task.sleep(for: .milliseconds(500))
        return true
    }
    let requested = OSAllocatedUnfairLock(initialState: false)
    config.handshakeTimeout = .milliseconds(300)
    config.password = {
        requested.withLock { $0 = true }
        try await Task.sleep(for: .seconds(1))
        return "test secret"
    }
    let session = SSHSession(config)
    await #expect(throws: TransportError.unreachable) { try await session.resume() }
    #expect(requested.withLock { $0 })
}
