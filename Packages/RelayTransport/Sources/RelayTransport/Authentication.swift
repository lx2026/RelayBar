import Foundation
import NIOCore
import NIOSSH

// NIOSSH invokes both delegates and the channel callbacks serially on the parent event loop.
final class Authentication: ChannelInboundHandler, NIOSSHClientUserAuthenticationDelegate, NIOSSHClientServerAuthenticationDelegate {
    typealias InboundIn = ByteBuffer
    let config: SessionConfiguration
    let publish: @Sendable (SessionState) -> Void
    let ready: EventLoopPromise<(SignInMethod, HostKey)>
    var method: SignInMethod?
    private var accepted: HostKey?
    private var remaining: TimeAmount
    private var deadline: NIODeadline?
    private var timeout: Scheduled<Void>?

    init(_ config: SessionConfiguration, ready: EventLoopPromise<(SignInMethod, HostKey)>,
         publish: @escaping @Sendable (SessionState) -> Void) {
        remaining = config.handshakeTimeout
        self.config = config
        self.ready = ready
        self.publish = publish
    }

    private func startTimer() {
        let deadline = NIODeadline.now() + remaining
        self.deadline = deadline
        timeout = ready.futureResult.eventLoop.scheduleTask(deadline: deadline) { [ready] in
            ready.fail(TransportError.unreachable)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        startTimer()
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        ready.futureResult.whenComplete { _ in
            bound.value.timeout?.cancel()
            bound.value.deadline = nil
        }
        // The SSH handler can consume channelInactive during a pending trust decision.
        context.channel.closeFuture.whenComplete { [ready] _ in ready.fail(TransportError.disconnected) }
        context.fireChannelActive()
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise promise: EventLoopPromise<Void>) {
        do {
            let key = try HostKey(hostKey)
            if let pin = accepted ?? config.pinnedKey, key != pin { throw TransportError.hostKeyChanged(key) }
            if accepted == key || config.pinnedKey == key {
                accepted = key
                promise.succeed(())
                return
            }
            publish(.verifying(key))
            if let deadline { remaining = deadline - .now() }
            timeout?.cancel()
            let bound = NIOLoopBound(self, eventLoop: promise.futureResult.eventLoop)
            let decision = promise.futureResult.eventLoop.makePromise(of: Bool.self)
            decision.futureResult.flatMapThrowing { approved in
                guard approved else { throw TransportError.hostKeyRefused }
                let auth = bound.value
                guard auth.deadline != nil else { throw TransportError.disconnected }
                auth.accepted = key
                auth.startTimer()
            }.cascade(to: promise)
            let verify = config.verify
            decision.completeWithTask { await verify(key) }
        } catch { promise.fail(error) }
    }

    func nextAuthenticationType(availableMethods methods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let user = config.username
        var offered: [SignInMethod] = []
        if methods.contains(.publicKey) { offered.append(.publicKey) }
        if methods.contains(.password) { offered.append(.password) }
        if methods.contains(.hostBased) { offered.append(.hostBased) }
        let refused = TransportError.signInRefused(offered)
        if method == nil {
            publish(.authenticating)
            method = SignInMethod.none
            promise.succeed(.init(username: user, serviceName: "ssh-connection", offer: .none))
        } else if method == SignInMethod.none, methods.contains(.publicKey), let signer = config.signer {
            method = .publicKey
            promise.completeWithTask {
                do {
                    let key = try await signer.signingKey()
                    return .init(username: user, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key.key)))
                } catch { throw Self.providerFailure(error, refused) }
            }
        } else if method != .password, methods.contains(.password), let password = config.password {
            method = .password
            promise.completeWithTask {
                do {
                    return try await .init(username: user, serviceName: "ssh-connection", offer: .password(.init(password: password())))
                } catch { throw Self.providerFailure(error, refused) }
            }
        } else {
            promise.fail(refused)
        }
    }

    // A failed signer or password prompt ends sign-in. Untranslated, it would read as a
    // network fault and the reconnect loop would ask the provider again.
    private static func providerFailure(_ error: Error, _ refused: TransportError) -> TransportError {
        if let error = error as? TransportError { return error }
        if error is CancellationError { return .cancelled }
        return refused
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, let method, let accepted { ready.succeed((method, accepted)) }
        if let event = event as? NIOUserAuthBannerEvent { config.banner(event.message) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ready.fail(TransportError.translate(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        deadline = nil
        timeout?.cancel()
        ready.fail(TransportError.disconnected)
        context.fireChannelInactive()
    }
}
