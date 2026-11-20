import CryptoKit
import Foundation
import NIOCore
import NIOSSH

public enum SignInMethod: String, Sendable { case none, publicKey, password, hostBased }

public struct HostKey: Sendable, Equatable {
    public let type: String
    public let fingerprint: String

    public init(type: String, fingerprint: String) {
        self.type = type
        self.fingerprint = fingerprint
    }

    init(_ key: NIOSSHPublicKey) throws {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        guard fields.count == 2, let bytes = Data(base64Encoded: String(fields[1])) else {
            throw TransportError.hostKeyRefused
        }
        type = String(fields[0])
        fingerprint = "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

public struct SigningKey: Sendable {
    let key: NIOSSHPrivateKey
    public init(_ key: Curve25519.Signing.PrivateKey) { self.key = .init(ed25519Key: key) }
    public init(_ key: P256.Signing.PrivateKey) { self.key = .init(p256Key: key) }
    public init(_ key: SecureEnclave.P256.Signing.PrivateKey) { self.key = .init(secureEnclaveP256Key: key) }
}

public protocol SSHSigner: Sendable {
    func signingKey() async throws -> SigningKey
}

extension SigningKey: SSHSigner {
    public func signingKey() async throws -> SigningKey { self }
}

public enum TransportError: Error, Equatable, Sendable {
    case unreachable, hostKeyRefused, hostKeyChanged(HostKey)
    case signInRefused([SignInMethod]), algorithmMismatch([String])
    case sftpUnavailable, forwardingProhibited, connectionRefused, cancelled
    case invalidEndpoint, disconnected

    static func translate(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError { return .cancelled }
        if let ssh = error as? NIOSSHError {
            if ssh.type == .keyExchangeNegotiationFailure {
                return .algorithmMismatch(["curve25519-sha256", "curve25519-sha256@libssh.org",
                    "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
                    "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                    "aes256-gcm@openssh.com", "aes128-gcm@openssh.com"])
            }
            // 0.15.1 exposes the RFC 4254 reason code only in this diagnostic.
            if ssh.type == .channelSetupRejected {
                if ssh.description.hasPrefix("NIOSSHError.channelSetupRejected: Reason: 1 ") { return .forwardingProhibited }
                if ssh.description.hasPrefix("NIOSSHError.channelSetupRejected: Reason: 2 ") { return .connectionRefused }
            }
        }
        return .unreachable
    }
}

public enum SessionState: Equatable, Sendable {
    case connecting, verifying(HostKey), authenticating, ready(SignInMethod)
    case interrupted(TransportError), failed(TransportError)
}

public struct SessionPolicy: Sendable {
    public var idle: Duration = .seconds(30)
    public var probeTimeout: Duration = .seconds(10)
    public var missedProbes = 2
    private var floor: Duration { max(.milliseconds(1), minimumBackoff) }
    var firstBackoffUpperBound: Duration { nextBackoffUpperBound(floor) }
    func nextBackoffUpperBound(_ upper: Duration) -> Duration { min(max(floor, maximumBackoff), upper * 2) }
    func backoff(upper: Duration, fraction: Double) -> Duration { floor + (upper - floor) * fraction }

    public var minimumBackoff: Duration = .seconds(1)
    public var maximumBackoff: Duration = .seconds(30)
    public init() {}
}

public struct SessionConfiguration: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var pinnedKey: HostKey?
    public var verify: @Sendable (HostKey) async -> Bool
    public var signer: (any SSHSigner)?
    public var password: (@Sendable () async throws -> String)?
    public var banner: @Sendable (String) -> Void = { _ in }
    public var policy = SessionPolicy()
    public var reads = ReadPolicy()
    var handshakeTimeout: TimeAmount = .seconds(120)
    var replyTimeout: TimeAmount = .seconds(30)

    public init(host: String, port: UInt16 = 22, username: String,
                verify: @escaping @Sendable (HostKey) async -> Bool) {
        self.host = host
        self.port = port
        self.username = username
        self.verify = verify
    }
}

func validHost(_ host: String) -> Bool {
    !host.isEmpty && host.utf8.count <= 1024 && !host.hasPrefix("-") &&
        host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
}

public struct ReadPolicy: Sendable {
    public var outstanding = 16
    public var requestBytes = 32 * 1024
    public var readAheadBytes = 2 * 1024 * 1024
    public init() {}
}
