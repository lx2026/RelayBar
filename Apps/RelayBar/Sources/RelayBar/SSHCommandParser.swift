import Foundation

enum SSHCommandParser {
    struct ImportedTunnel: Equatable {
        var rules: [ForwardingRule]
        var sshHost: String
        var additionalArguments: [String]
        var reverseSOCKSPolicy: ReverseSOCKSPolicy?
        var streamLocalSettings: StreamLocalSettings
    }

    enum ParseError: LocalizedError, Equatable {
        case empty
        case notSSH
        case unclosedQuote
        case missingForward
        case invalidForward
        case missingHost
        case missingOptionValue(String)
        case unsupportedOption(String)
        case unsafeOption(String)
        case conflictingOption(String)
        case remoteCommand

        var errorDescription: String? {
            switch self {
            case .empty:
                "Paste an SSH command first."
            case .notSSH:
                "The command needs to start with ssh."
            case .unclosedQuote:
                "One of the quotes in the command is not closed."
            case .missingForward:
                "The command needs at least one -L, -D, or -R forward."
            case .invalidForward:
                "One forwarding rule has an invalid listen or destination endpoint."
            case .missingHost:
                "The SSH host is missing."
            case .missingOptionValue(let option):
                "\(option) needs a value."
            case .unsupportedOption(let option):
                "\(option) is not supported by the quick importer."
            case .unsafeOption(let option):
                "\(option) is blocked because it can execute commands or access arbitrary files."
            case .conflictingOption(let option):
                "\(option) is specified more than once with ambiguous values."
            case .remoteCommand:
                "RelayBar imports forwarding commands, not remote commands."
            }
        }
    }

    static func parse(_ command: String) throws -> ImportedTunnel {
        let tokens = try tokenize(command)
        guard !tokens.isEmpty else { throw ParseError.empty }

        let executable = URL(fileURLWithPath: tokens[0]).lastPathComponent
        guard executable == "ssh" else { throw ParseError.notSSH }

        var rules: [ForwardingRule] = []
        var sshHost: String?
        var extraArguments: [String] = []
        var reverseSOCKSPolicy: ReverseSOCKSPolicy?
        var streamBindMask: UInt16?
        var streamUnlink: Bool?
        var index = 1

        let flagsToDiscard: Set<String> = ["-N", "-T", "-n", "-f"]
        while index < tokens.count {
            let token = tokens[index]

            if sshHost != nil {
                throw ParseError.remoteCommand
            }

            if token == "--" {
                index += 1
                guard index < tokens.count else { throw ParseError.missingHost }
                sshHost = tokens[index]
            } else if ["-L", "-D", "-R"].contains(token) {
                index += 1
                guard index < tokens.count else {
                    throw ParseError.missingOptionValue(token)
                }
                rules.append(try parseForward(option: token, specification: tokens[index]))
            } else if let option = ["-L", "-D", "-R"].first(where: {
                token.hasPrefix($0) && token.count > $0.count
            }) {
                rules.append(
                    try parseForward(
                        option: option,
                        specification: String(token.dropFirst(option.count))
                    )
                )
            } else if flagsToDiscard.contains(token) {
                // RelayBar owns the process and supplies these management flags itself.
            } else if SSHArgumentPolicy.allowedFlags.contains(token) {
                extraArguments.append(token)
            } else if SSHArgumentPolicy.optionsWithValues.contains(token) {
                index += 1
                guard index < tokens.count else {
                    throw ParseError.missingOptionValue(token)
                }
                let value = tokens[index]
                if token == "-o" {
                    try consumeOpenSSHOption(
                        value,
                        original: "-o \(value)",
                        reverseSOCKSPolicy: &reverseSOCKSPolicy,
                        streamBindMask: &streamBindMask,
                        streamUnlink: &streamUnlink,
                        extraArguments: &extraArguments
                    )
                } else {
                    guard SSHArgumentPolicy.isSafeOptionValue(value) else {
                        throw ParseError.unsafeOption("\(token) \(value)")
                    }
                    extraArguments.append(contentsOf: [token, value])
                }
            } else if token.hasPrefix("-") {
                guard let prefix = SSHArgumentPolicy.attachedOptionPrefixes.first(where: {
                    token.hasPrefix($0) && token.count > $0.count
                }) else {
                    throw ParseError.unsupportedOption(token)
                }

                let value = String(token.dropFirst(prefix.count))
                if prefix == "-o" {
                    try consumeOpenSSHOption(
                        value,
                        original: token,
                        reverseSOCKSPolicy: &reverseSOCKSPolicy,
                        streamBindMask: &streamBindMask,
                        streamUnlink: &streamUnlink,
                        extraArguments: &extraArguments
                    )
                } else {
                    guard SSHArgumentPolicy.isSafeOptionValue(value) else {
                        throw ParseError.unsafeOption(token)
                    }
                    extraArguments.append(token)
                }
            } else {
                sshHost = token
            }

            index += 1
        }

        guard !rules.isEmpty else { throw ParseError.missingForward }
        guard let sshHost, SSHArgumentPolicy.isValidHostTarget(sshHost) else {
            throw ParseError.missingHost
        }

        if rules.contains(where: { $0.kind == .remoteDynamic }),
           reverseSOCKSPolicy == nil {
            reverseSOCKSPolicy = .any
        }

        return ImportedTunnel(
            rules: rules,
            sshHost: sshHost,
            additionalArguments: extraArguments,
            reverseSOCKSPolicy: reverseSOCKSPolicy,
            streamLocalSettings: StreamLocalSettings(
                bindMask: streamBindMask ?? 0o177,
                unlinkStaleSocket: streamUnlink ?? false
            )
        )
    }

    private static func consumeOpenSSHOption(
        _ value: String,
        original: String,
        reverseSOCKSPolicy: inout ReverseSOCKSPolicy?,
        streamBindMask: inout UInt16?,
        streamUnlink: inout Bool?,
        extraArguments: inout [String]
    ) throws {
        guard let option = SSHArgumentPolicy.splitOpenSSHOption(value) else {
            throw ParseError.unsafeOption(original)
        }

        switch option.key.lowercased() {
        case "permitremoteopen":
            guard reverseSOCKSPolicy == nil else {
                throw ParseError.conflictingOption("PermitRemoteOpen")
            }
            reverseSOCKSPolicy = try parsePermitRemoteOpen(option.value)
        case "streamlocalbindmask":
            guard streamBindMask == nil else {
                throw ParseError.conflictingOption("StreamLocalBindMask")
            }
            guard
                !option.value.isEmpty,
                option.value.allSatisfy({ ("0"..."7").contains(String($0)) }),
                let mask = UInt16(option.value, radix: 8),
                mask <= 0o777
            else {
                throw ParseError.unsafeOption(original)
            }
            streamBindMask = mask
        case "streamlocalbindunlink":
            guard streamUnlink == nil else {
                throw ParseError.conflictingOption("StreamLocalBindUnlink")
            }
            switch option.value.lowercased() {
            case "yes":
                streamUnlink = true
            case "no":
                streamUnlink = false
            default:
                throw ParseError.unsafeOption(original)
            }
        default:
            guard SSHArgumentPolicy.isSafeOpenSSHOption(value) else {
                throw ParseError.unsafeOption(original)
            }
            extraArguments.append(contentsOf: ["-o", value])
        }
    }

    private static func parsePermitRemoteOpen(
        _ value: String
    ) throws -> ReverseSOCKSPolicy {
        switch value.lowercased() {
        case "any":
            return .any
        case "none":
            return .none
        default:
            let destinations = value.split(whereSeparator: \.isWhitespace).map(String.init)
            guard
                !destinations.isEmpty,
                destinations.allSatisfy(
                    SSHArgumentPolicy.isValidPermitRemoteOpenDestination
                )
            else {
                throw ParseError.unsafeOption("-o PermitRemoteOpen=\(value)")
            }
            return .allow(destinations)
        }
    }

    private static func parseForward(
        option: String,
        specification: String
    ) throws -> ForwardingRule {
        let rule: ForwardingRule
        switch option {
        case "-L":
            rule = try parseFixedForward(
                kind: .local,
                specification: specification
            )
        case "-D":
            rule = ForwardingRule(
                kind: .localDynamic,
                listen: try parseTCPListen(specification),
                destination: nil
            )
        case "-R":
            if let fixed = try? parseFixedForward(
                kind: .remote,
                specification: specification
            ) {
                rule = fixed
            } else {
                rule = ForwardingRule(
                    kind: .remoteDynamic,
                    listen: try parseTCPListen(specification),
                    destination: nil
                )
            }
        default:
            throw ParseError.unsupportedOption(option)
        }

        var normalized = rule
        if normalized.listen.kind == .tcp,
           normalized.listen.tcp?.bindAddress == nil {
            normalized.listen.tcp?.bindAddress = "localhost"
        }
        guard normalized.isValid else { throw ParseError.invalidForward }
        return normalized
    }

    private static func parseFixedForward(
        kind: ForwardingRuleKind,
        specification: String
    ) throws -> ForwardingRule {
        let parts = try splitForwardSpecification(specification)
        let listen: ForwardListenEndpoint
        let destination: ForwardDestinationEndpoint

        if parts.first?.hasPrefix("/") == true {
            guard let path = parts.first, SSHArgumentPolicy.isValidSocketPath(path) else {
                throw ParseError.invalidForward
            }
            listen = .unix(path: path)
            if parts.count == 2, parts[1].hasPrefix("/") {
                destination = .unix(path: parts[1])
            } else if parts.count == 3 {
                destination = try parseTCPDestination(
                    host: parts[1],
                    port: parts[2]
                )
            } else {
                throw ParseError.invalidForward
            }
        } else if parts.last?.hasPrefix("/") == true {
            let destinationPath = parts[parts.count - 1]
            guard SSHArgumentPolicy.isValidSocketPath(destinationPath) else {
                throw ParseError.invalidForward
            }
            destination = .unix(path: destinationPath)
            switch parts.count {
            case 2:
                listen = try parseTCPListenParts(bind: nil, port: parts[0])
            case 3:
                listen = try parseTCPListenParts(bind: parts[0], port: parts[1])
            default:
                throw ParseError.invalidForward
            }
        } else {
            switch parts.count {
            case 3:
                listen = try parseTCPListenParts(bind: nil, port: parts[0])
                destination = try parseTCPDestination(
                    host: parts[1],
                    port: parts[2]
                )
            case 4:
                listen = try parseTCPListenParts(bind: parts[0], port: parts[1])
                destination = try parseTCPDestination(
                    host: parts[2],
                    port: parts[3]
                )
            default:
                throw ParseError.invalidForward
            }
        }

        return ForwardingRule(
            kind: kind,
            listen: listen,
            destination: destination
        )
    }

    private static func parseTCPListen(
        _ specification: String
    ) throws -> ForwardListenEndpoint {
        let parts = try splitForwardSpecification(specification)
        switch parts.count {
        case 1:
            return try parseTCPListenParts(bind: nil, port: parts[0])
        case 2:
            return try parseTCPListenParts(bind: parts[0], port: parts[1])
        default:
            throw ParseError.invalidForward
        }
    }

    private static func parseTCPListenParts(
        bind: String?,
        port: String
    ) throws -> ForwardListenEndpoint {
        guard let port = Int(port), (0...65_535).contains(port) else {
            throw ParseError.invalidForward
        }
        let bindAddress = bind.map(SSHForwardingFormat.unbracket)
        guard SSHArgumentPolicy.isValidBindAddress(bindAddress) else {
            throw ParseError.invalidForward
        }
        return .tcp(bindAddress: bindAddress, port: port)
    }

    private static func parseTCPDestination(
        host: String,
        port: String
    ) throws -> ForwardDestinationEndpoint {
        let host = SSHForwardingFormat.unbracket(host)
        guard
            SSHArgumentPolicy.isValidDestinationHost(host),
            let port = Int(port),
            (1...65_535).contains(port)
        else {
            throw ParseError.invalidForward
        }
        return .tcp(host: host, port: port)
    }

    private static func splitForwardSpecification(
        _ specification: String
    ) throws -> [String] {
        guard
            !specification.isEmpty,
            !specification.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
            })
        else {
            throw ParseError.invalidForward
        }

        var parts: [String] = []
        var current = ""
        var bracketDepth = 0
        for character in specification {
            switch character {
            case "[":
                bracketDepth += 1
                guard bracketDepth == 1 else { throw ParseError.invalidForward }
                current.append(character)
            case "]":
                bracketDepth -= 1
                guard bracketDepth == 0 else { throw ParseError.invalidForward }
                current.append(character)
            case ":" where bracketDepth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        guard bracketDepth == 0 else { throw ParseError.invalidForward }
        parts.append(current)
        return parts
    }

    private static func tokenize(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var tokenStarted = false

        for character in command.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escaping {
                current.append(character)
                tokenStarted = true
                escaping = false
                continue
            }

            if character == "\\", quote != "'" {
                escaping = true
                tokenStarted = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
            } else if character == "\"" || character == "'" {
                quote = character
                tokenStarted = true
            } else if character.isWhitespace {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
            } else {
                current.append(character)
                tokenStarted = true
            }
        }

        guard quote == nil else { throw ParseError.unclosedQuote }
        if escaping { current.append("\\") }
        if tokenStarted { tokens.append(current) }
        return tokens
    }
}
