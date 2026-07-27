import Foundation

struct RemoteServer: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable, CaseIterable {
        case recent
        case saved
        case forwardingProfile
        case sshConfig

        static let pickerOrder: [Source] = [
            .recent,
            .saved,
            .forwardingProfile,
            .sshConfig
        ]

        var pickerSectionTitle: String {
            switch self {
            case .recent: "Recent"
            case .saved: "Saved Hosts"
            case .forwardingProfile: "Port Forwarding"
            case .sshConfig: "SSH Config"
            }
        }
    }

    struct ConnectionIdentity: Hashable, Sendable {
        let sshHost: String
        let additionalArguments: [String]
    }

    let id: UUID
    let name: String
    let sshHost: String
    let additionalArguments: [String]
    let source: Source

    init(
        id: UUID,
        name: String,
        sshHost: String,
        additionalArguments: [String],
        source: Source = .saved
    ) {
        self.id = id
        self.name = name
        self.sshHost = sshHost
        self.additionalArguments = additionalArguments
        self.source = source
    }

    init(tunnel: Tunnel) {
        id = tunnel.id
        sshHost = tunnel.sshHost
        additionalArguments = tunnel.additionalArguments
        source = .forwardingProfile

        let savedName = tunnel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedSingleRuleName = tunnel.rules.first?.displaySummary
        let generatedMultiRuleName = "\(tunnel.sshHost) · \(tunnel.rules.count) rules"
        if
            savedName.isEmpty
                || savedName == tunnel.destinationEndpoint
                || savedName == generatedSingleRuleName
                || savedName == generatedMultiRuleName
        {
            name = tunnel.sshHost
        } else {
            name = savedName
        }
    }

    var displayName: String {
        name == sshHost ? name : "\(name) — \(sshHost)"
    }

    var connectionIdentity: ConnectionIdentity {
        ConnectionIdentity(
            sshHost: sshHost,
            additionalArguments: additionalArguments
        )
    }
}

struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory
        case file
        case symbolicLink
    }

    let name: String
    let path: String
    let kind: Kind
    let size: Int64?
    let modificationText: String

    var id: String { path }
    var isDirectory: Bool { kind == .directory }

    var isPreviewableImage: Bool {
        guard kind == .file else { return false }
        return Self.previewableImageExtensions.contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        )
    }

    var isPreviewableMarkdown: Bool {
        guard kind == .file else { return false }
        return Self.previewableMarkdownExtensions.contains(
            URL(fileURLWithPath: name).pathExtension.lowercased()
        )
    }

    var isPreviewable: Bool {
        isPreviewableImage || isPreviewableMarkdown
    }

    private static let previewableImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff"
    ]

    private static let previewableMarkdownExtensions: Set<String> = [
        "markdown", "md", "mdown", "mkd"
    ]
}

enum RemotePath {
    static let maximumUTF8ByteCount = 32 * 1_024

    static func validationMessage(for value: String) -> String? {
        guard !value.isEmpty else {
            return "Paste an absolute path from remote pwd."
        }
        guard value.hasPrefix("/") else {
            return "The remote path must start with /."
        }
        guard value.utf8.count <= maximumUTF8ByteCount else {
            return "The remote path is too long."
        }
        guard !containsControlCharacters(value) else {
            return "The remote path cannot contain line breaks or control characters."
        }
        return nil
    }

    static func normalized(_ value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let previous = value.index(before: end)
            guard value[previous] == "/" else { break }
            guard previous > value.startIndex else { return "/" }
            end = previous
        }
        return String(value[..<end])
    }

    static func joining(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    static func parent(of path: String) -> String {
        let normalizedPath = normalized(path)
        guard normalizedPath != "/" else { return "/" }
        let parent = (normalizedPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// Escaping `\` and `"` is sufficient, and deliberately so. sftp's own
    /// quoting suppresses `glob(3)` expansion: inside a quoted argument it
    /// escapes metacharacters before globbing, so `*`, `?`, and `[` are matched
    /// literally. Verified against OpenSSH 10.2 with directories named
    /// `star*dir`, `report[2026]`, `bra[ck]et.md`, and `draft?.md`, all of which
    /// resolve correctly. Do not add metacharacter escaping or rejection here;
    /// either one breaks paths that work today.
    static func batchQuoted(_ value: String) throws -> String {
        guard
            value.utf8.count <= maximumUTF8ByteCount,
            !containsControlCharacters(value)
        else {
            throw RemoteFileError.invalidPath
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0)
        }
    }
}

enum RemoteFileError: LocalizedError, Equatable {
    case invalidConnection
    case invalidPath
    case tooManyEntries
    case responseTooLarge
    case previewTooLarge
    case markdownTooLarge
    case invalidMarkdownEncoding
    case imageDimensionsTooLarge
    case unsupportedImage
    case malformedListing
    case commandFailed(String)
    case missingDownload

    var errorDescription: String? {
        switch self {
        case .invalidConnection:
            return "This saved server contains an invalid host or blocked SSH option."
        case .invalidPath:
            return "The remote path is not valid."
        case .tooManyEntries:
            return "This folder contains too many items to show safely."
        case .responseTooLarge:
            return "The remote server returned more data than RelayBar can process safely."
        case .previewTooLarge:
            return "This file is too large to preview. Download it instead."
        case .markdownTooLarge:
            return "This Markdown file is too large to preview safely. Download it instead."
        case .invalidMarkdownEncoding:
            return "This Markdown file is not valid UTF-8. Download it instead."
        case .imageDimensionsTooLarge:
            return "This image’s dimensions are too large to preview safely. Download it instead."
        case .unsupportedImage:
            return "This image could not be decoded safely."
        case .malformedListing:
            return "RelayBar could not read this folder listing."
        case .commandFailed(let message):
            return message
        case .missingDownload:
            return "The transfer finished without creating the requested item."
        }
    }
}

enum SFTPCommandBuilder {
    static func processArguments(for server: RemoteServer) throws -> [String] {
        guard
            SSHArgumentPolicy.isValidHostTarget(server.sshHost),
            SSHArgumentPolicy.areAdditionalArgumentsSafe(server.additionalArguments)
        else {
            throw RemoteFileError.invalidConnection
        }

        var result = [
            "-b", "-",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10"
        ]
        var index = 0

        while index < server.additionalArguments.count {
            let argument = server.additionalArguments[index]

            if SSHArgumentPolicy.allowedFlags.contains(argument) {
                switch argument {
                case "-k":
                    result += ["-o", "GSSAPIDelegateCredentials=no"]
                default:
                    result.append(argument)
                }
                index += 1
                continue
            }

            if SSHArgumentPolicy.optionsWithValues.contains(argument) {
                index += 1
                guard index < server.additionalArguments.count else {
                    throw RemoteFileError.invalidConnection
                }
                append(option: argument, value: server.additionalArguments[index], to: &result)
                index += 1
                continue
            }

            guard let prefix = SSHArgumentPolicy.attachedOptionPrefixes.first(where: {
                argument.hasPrefix($0) && argument.count > $0.count
            }) else {
                throw RemoteFileError.invalidConnection
            }
            append(
                option: prefix,
                value: String(argument.dropFirst(prefix.count)),
                to: &result
            )
            index += 1
        }

        result.append(server.sshHost)
        return result
    }

    static func listCommand(path: String) throws -> String {
        "ls -la \(try RemotePath.batchQuoted(path))\n"
    }

    static func downloadCommand(
        remotePath: String,
        localPath: String,
        recursively: Bool
    ) throws -> String {
        let recursiveFlag = recursively ? "-R " : ""
        return "get \(recursiveFlag)\(try RemotePath.batchQuoted(remotePath)) \(try RemotePath.batchQuoted(localPath))\n"
    }

    private static func append(option: String, value: String, to result: inout [String]) {
        switch option {
        case "-p":
            result += ["-P", value]
        case "-l":
            result += ["-o", "User=\(value)"]
        default:
            result += [option, value]
        }
    }
}

enum SFTPListingParser {
    static let maximumEntryCount = 10_000
    static let maximumListingLineUTF8ByteCount = 32 * 1_024
    static let maximumEntryNameUTF8ByteCount = 4 * 1_024

    static func parse(_ output: String, parentPath: String) throws -> [RemoteFileEntry] {
        var entries: [RemoteFileEntry] = []
        var sawStructuredListingLine = false

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard rawLine.utf8.count <= maximumListingLineUTF8ByteCount else {
                throw RemoteFileError.malformedListing
            }
            let line = String(rawLine)
            let fields = line.split(
                maxSplits: 8,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 9 else { continue }

            let permissions = String(fields[0])
            guard permissions.count >= 10 else { continue }
            guard let size = Int64(fields[4]), size >= 0 else { continue }
            sawStructuredListingLine = true

            var listedName = String(fields[8])
            let kind: RemoteFileEntry.Kind
            switch permissions.first {
            case "d":
                kind = .directory
            case "l":
                kind = .symbolicLink
                if let separator = listedName.range(of: " -> ") {
                    listedName = String(listedName[..<separator.lowerBound])
                }
            case "-":
                kind = .file
            default:
                continue
            }

            let name: String
            if listedName.hasPrefix("/") {
                let normalizedParent = RemotePath.normalized(parentPath)
                let expectedPrefix = normalizedParent == "/"
                    ? "/"
                    : "\(normalizedParent)/"
                guard listedName.hasPrefix(expectedPrefix) else {
                    throw RemoteFileError.malformedListing
                }
                name = String(listedName.dropFirst(expectedPrefix.count))
            } else {
                name = listedName
            }

            guard name.utf8.count <= maximumEntryNameUTF8ByteCount else {
                throw RemoteFileError.malformedListing
            }
            guard name != ".", name != "..", isSafeEntryName(name) else { continue }
            let entryPath = RemotePath.joining(parentPath, name)
            guard RemotePath.validationMessage(for: entryPath) == nil else {
                throw RemoteFileError.malformedListing
            }
            entries.append(
                RemoteFileEntry(
                    name: name,
                    path: entryPath,
                    kind: kind,
                    size: kind == .directory ? nil : size,
                    modificationText: "\(fields[5]) \(fields[6]) \(fields[7])"
                )
            )

            guard entries.count <= maximumEntryCount else {
                throw RemoteFileError.tooManyEntries
            }
        }

        if entries.isEmpty, !sawStructuredListingLine {
            let hasUnexpectedOutput = output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .contains {
                    !$0.isEmpty
                        && !$0.hasPrefix("sftp>")
                        && !$0.hasPrefix("Connected to ")
                        && !$0.hasSuffix(":")
                        && !$0.hasPrefix("total ")
                }
            if hasUnexpectedOutput {
                throw RemoteFileError.malformedListing
            }
        }

        return entries.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
            }
    }
}
