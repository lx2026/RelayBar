import Foundation

struct Tunnel: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var localPort: Int
    var destinationHost: String
    var destinationPort: Int
    var sshHost: String
    var bindAddress: String?
    var additionalArguments: [String]

    init(
        id: UUID = UUID(),
        name: String,
        localPort: Int,
        destinationHost: String,
        destinationPort: Int,
        sshHost: String,
        bindAddress: String? = nil,
        additionalArguments: [String] = []
    ) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.sshHost = sshHost
        self.bindAddress = bindAddress
        self.additionalArguments = additionalArguments
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, localPort, destinationHost, destinationPort, sshHost
        case bindAddress, additionalArguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        localPort = try container.decode(Int.self, forKey: .localPort)
        destinationHost = try container.decode(String.self, forKey: .destinationHost)
        destinationPort = try container.decode(Int.self, forKey: .destinationPort)
        sshHost = try container.decode(String.self, forKey: .sshHost)
        bindAddress = try container.decodeIfPresent(String.self, forKey: .bindAddress)
        additionalArguments = try container.decodeIfPresent([String].self, forKey: .additionalArguments) ?? []
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "\(destinationHost):\(destinationPort)" : trimmedName
    }

    var forwardSpec: String {
        let local = bindAddress.map { "\($0):\(localPort)" } ?? String(localPort)
        let destination = destinationHost.contains(":") && !destinationHost.hasPrefix("[")
            ? "[\(destinationHost)]"
            : destinationHost
        return "\(local):\(destination):\(destinationPort)"
    }

    var localEndpoint: String {
        let host = bindAddress.flatMap { $0.isEmpty ? nil : $0 } ?? "localhost"
        return "\(host):\(localPort)"
    }

    var destinationEndpoint: String {
        "\(destinationHost):\(destinationPort)"
    }

    var exposesBeyondLoopback: Bool {
        guard let bindAddress else { return false }
        let normalized = bindAddress
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return !["localhost", "127.0.0.1", "::1"].contains(normalized)
    }

    var isSafeToRun: Bool {
        (1...65_535).contains(localPort)
            && (1...65_535).contains(destinationPort)
            && SSHArgumentPolicy.isValidHostTarget(sshHost)
            && SSHArgumentPolicy.isValidDestinationHost(destinationHost)
            && SSHArgumentPolicy.areAdditionalArgumentsSafe(additionalArguments)
    }
}

enum TunnelPhase: Equatable {
    case stopped
    case starting
    case retrying(attempt: Int, maxAttempts: Int, delay: TimeInterval, message: String)
    case running
    case failed(String)
}
