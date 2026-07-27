import Foundation

enum RemoteServerCatalogError: LocalizedError, Equatable {
    case invalidHost
    case invalidName
    case duplicateSavedHost
    case savedHostLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Enter a valid SSH host such as user@server."
        case .invalidName:
            return "The optional name is too long or contains unsupported characters."
        case .duplicateSavedHost:
            return "This SSH host is already saved in RelayBar."
        case .savedHostLimitReached:
            return "RelayBar can save up to 128 standalone SSH hosts."
        }
    }
}

enum SSHConfigHostReader {
    static let maximumFileSize = 1 * 1_024 * 1_024
    static let maximumHostCount = 256

    static func load(from url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        } catch {
            return []
        }
        guard
            data.count <= maximumFileSize,
            let contents = String(data: data, encoding: .utf8)
        else {
            return []
        }
        return parse(contents)
    }

    static func parse(_ contents: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard
                fields.count > 1,
                fields[0].caseInsensitiveCompare("Host") == .orderedSame
            else {
                continue
            }

            for rawHost in fields.dropFirst() {
                let host = unquoted(rawHost)
                guard
                    !host.hasPrefix("!"),
                    !host.contains(where: { "*?[".contains($0) }),
                    host.utf8.count <= 1_024,
                    SSHArgumentPolicy.isValidHostTarget(host)
                else {
                    continue
                }

                let key = host.lowercased()
                guard seen.insert(key).inserted else { continue }
                result.append(host)
                if result.count == maximumHostCount {
                    return result
                }
            }
        }

        return result
    }

    private static func unquoted(_ value: String) -> String {
        guard
            value.count >= 2,
            let first = value.first,
            let last = value.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

@MainActor
final class RemoteServerCatalog {
    private struct Record: Codable {
        let id: UUID
        let name: String
        let sshHost: String
        let additionalArguments: [String]

        init(server: RemoteServer) {
            id = server.id
            name = server.name
            sshHost = server.sshHost
            additionalArguments = server.additionalArguments
        }

        func server(source: RemoteServer.Source) -> RemoteServer {
            RemoteServer(
                id: id,
                name: name,
                sshHost: sshHost,
                additionalArguments: additionalArguments,
                source: source
            )
        }

        var connectionIdentity: RemoteServer.ConnectionIdentity {
            RemoteServer.ConnectionIdentity(
                sshHost: sshHost,
                additionalArguments: additionalArguments
            )
        }
    }

    private static let savedLimit = 128
    private static let recentLimit = 8
    private static let savedStorageKey = "remoteFiles.savedServers.v1"
    private static let recentStorageKey = "remoteFiles.recentServers.v1"

    private let defaults: UserDefaults?
    private let sshConfigURL: URL?
    private var savedRecords: [Record]
    private var recentRecords: [Record]

    init(defaults: UserDefaults? = nil, sshConfigURL: URL? = nil) {
        self.defaults = defaults
        self.sshConfigURL = sshConfigURL
        savedRecords = Self.loadRecords(
            from: defaults,
            key: Self.savedStorageKey,
            limit: Self.savedLimit
        )
        recentRecords = Self.loadRecords(
            from: defaults,
            key: Self.recentStorageKey,
            limit: Self.recentLimit
        )
    }

    static func appDefault() -> RemoteServerCatalog {
        RemoteServerCatalog(
            defaults: .standard,
            sshConfigURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/config")
        )
    }

    func servers(from tunnels: [Tunnel]) -> [RemoteServer] {
        let recent = recentRecords.map { $0.server(source: .recent) }
        let saved = savedRecords
            .map { $0.server(source: .saved) }
            .sorted(by: Self.sortByDisplayName)
        let profiles = Self.profileServers(from: tunnels)
        let config = (sshConfigURL.map(SSHConfigHostReader.load) ?? [])
            .map {
                RemoteServer(
                    id: UUID(),
                    name: $0,
                    sshHost: $0,
                    additionalArguments: [],
                    source: .sshConfig
                )
            }
            .sorted(by: Self.sortByDisplayName)

        var result: [RemoteServer] = []
        var seen: Set<RemoteServer.ConnectionIdentity> = []
        for server in recent + saved + profiles + config {
            guard seen.insert(server.connectionIdentity).inserted else { continue }
            result.append(server)
        }
        return result
    }

    func add(name: String, sshHost: String) throws -> RemoteServer {
        let normalizedHost = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            normalizedHost.utf8.count <= 1_024,
            SSHArgumentPolicy.isValidHostTarget(normalizedHost)
        else {
            throw RemoteServerCatalogError.invalidHost
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            normalizedName.utf8.count <= 256,
            !normalizedName.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
            })
        else {
            throw RemoteServerCatalogError.invalidName
        }

        let server = RemoteServer(
            id: UUID(),
            name: normalizedName.isEmpty ? normalizedHost : normalizedName,
            sshHost: normalizedHost,
            additionalArguments: [],
            source: .saved
        )
        guard
            !savedRecords.contains(where: {
                $0.connectionIdentity == server.connectionIdentity
            })
        else {
            throw RemoteServerCatalogError.duplicateSavedHost
        }
        guard savedRecords.count < Self.savedLimit else {
            throw RemoteServerCatalogError.savedHostLimitReached
        }

        savedRecords.append(Record(server: server))
        persist(savedRecords, key: Self.savedStorageKey)
        return server
    }

    func isSavedServer(id: UUID) -> Bool {
        savedRecords.contains { $0.id == id }
    }

    func removeSavedServer(id: UUID) {
        guard let removed = savedRecords.first(where: { $0.id == id }) else { return }
        savedRecords.removeAll { $0.id == id }
        recentRecords.removeAll {
            $0.connectionIdentity == removed.connectionIdentity
        }
        persist(savedRecords, key: Self.savedStorageKey)
        persist(recentRecords, key: Self.recentStorageKey)
    }

    func recordSuccessfulOpen(_ server: RemoteServer) {
        if recentRecords.first?.connectionIdentity == server.connectionIdentity {
            return
        }
        recentRecords.removeAll {
            $0.connectionIdentity == server.connectionIdentity
        }
        recentRecords.insert(Record(server: server), at: 0)
        if recentRecords.count > Self.recentLimit {
            recentRecords.removeLast(recentRecords.count - Self.recentLimit)
        }
        persist(recentRecords, key: Self.recentStorageKey)
    }

    private func persist(_ records: [Record], key: String) {
        guard let defaults, let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadRecords(
        from defaults: UserDefaults?,
        key: String,
        limit: Int
    ) -> [Record] {
        guard
            let data = defaults?.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else {
            return []
        }

        var result: [Record] = []
        var seen: Set<RemoteServer.ConnectionIdentity> = []
        for record in decoded.prefix(limit) {
            guard
                !record.name.isEmpty,
                record.name.utf8.count <= 256,
                !record.name.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                        || CharacterSet.newlines.contains($0)
                }),
                record.sshHost.utf8.count <= 1_024,
                SSHArgumentPolicy.isValidHostTarget(record.sshHost),
                SSHArgumentPolicy.areAdditionalArgumentsSafe(record.additionalArguments),
                seen.insert(record.connectionIdentity).inserted
            else {
                continue
            }
            result.append(record)
        }
        return result
    }

    private static func profileServers(from tunnels: [Tunnel]) -> [RemoteServer] {
        var serversByConnection: [RemoteServer.ConnectionIdentity: RemoteServer] = [:]
        var duplicateConnections: Set<RemoteServer.ConnectionIdentity> = []

        for tunnel in tunnels {
            let server = RemoteServer(tunnel: tunnel)
            if serversByConnection[server.connectionIdentity] == nil {
                serversByConnection[server.connectionIdentity] = server
            } else {
                duplicateConnections.insert(server.connectionIdentity)
            }
        }

        return serversByConnection.map { identity, server in
            guard duplicateConnections.contains(identity) else { return server }
            return RemoteServer(
                id: server.id,
                name: server.sshHost,
                sshHost: server.sshHost,
                additionalArguments: server.additionalArguments,
                source: .forwardingProfile
            )
        }
        .sorted(by: sortByDisplayName)
    }

    private static func sortByDisplayName(_ lhs: RemoteServer, _ rhs: RemoteServer) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}
