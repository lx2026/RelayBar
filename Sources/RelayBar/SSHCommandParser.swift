import Foundation

enum SSHCommandParser {
    struct ImportedTunnel: Equatable {
        var localPort: Int
        var destinationHost: String
        var destinationPort: Int
        var sshHost: String
        var bindAddress: String?
        var additionalArguments: [String]
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
        case remoteCommand

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Paste an SSH command first."
            case .notSSH:
                return "The command needs to start with ssh."
            case .unclosedQuote:
                return "One of the quotes in the command is not closed."
            case .missingForward:
                return "The command needs one -L forward."
            case .invalidForward:
                return "Use -L localPort:host:remotePort."
            case .missingHost:
                return "The SSH host is missing."
            case .missingOptionValue(let option):
                return "\(option) needs a value."
            case .unsupportedOption(let option):
                return "\(option) is not supported by the quick importer."
            case .unsafeOption(let option):
                return "\(option) is blocked because it can execute commands or access arbitrary files."
            case .remoteCommand:
                return "RelayBar only imports forwarding commands, not remote commands."
            }
        }
    }

    static func parse(_ command: String) throws -> ImportedTunnel {
        let tokens = try tokenize(command)
        guard !tokens.isEmpty else { throw ParseError.empty }

        let executable = URL(fileURLWithPath: tokens[0]).lastPathComponent
        guard executable == "ssh" else { throw ParseError.notSSH }

        var forward: String?
        var sshHost: String?
        var extraArguments: [String] = []
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
            } else if token == "-L" {
                index += 1
                guard index < tokens.count else { throw ParseError.missingOptionValue("-L") }
                guard forward == nil else { throw ParseError.unsupportedOption("Multiple -L forwards") }
                forward = tokens[index]
            } else if token.hasPrefix("-L"), token.count > 2 {
                guard forward == nil else { throw ParseError.unsupportedOption("Multiple -L forwards") }
                forward = String(token.dropFirst(2))
            } else if flagsToDiscard.contains(token) {
                // RelayBar supplies these itself. In particular, -f would detach SSH
                // and make it impossible for the app to manage the process.
            } else if SSHArgumentPolicy.allowedFlags.contains(token) {
                extraArguments.append(token)
            } else if SSHArgumentPolicy.optionsWithValues.contains(token) {
                index += 1
                guard index < tokens.count else { throw ParseError.missingOptionValue(token) }
                if token == "-o", !SSHArgumentPolicy.isSafeOpenSSHOption(tokens[index]) {
                    throw ParseError.unsafeOption("-o \(tokens[index])")
                }
                extraArguments.append(contentsOf: [token, tokens[index]])
            } else if token.hasPrefix("-") {
                if let prefix = SSHArgumentPolicy.attachedOptionPrefixes.first(where: {
                    token.hasPrefix($0) && token.count > $0.count
                }) {
                    if prefix == "-o", !SSHArgumentPolicy.isSafeOpenSSHOption(String(token.dropFirst(2))) {
                        throw ParseError.unsafeOption(token)
                    }
                    extraArguments.append(token)
                } else {
                    throw ParseError.unsupportedOption(token)
                }
            } else {
                sshHost = token
            }

            index += 1
        }

        guard let forward else { throw ParseError.missingForward }
        guard let sshHost, SSHArgumentPolicy.isValidHostTarget(sshHost) else { throw ParseError.missingHost }
        let parsedForward = try parseForward(forward)

        return ImportedTunnel(
            localPort: parsedForward.localPort,
            destinationHost: parsedForward.destinationHost,
            destinationPort: parsedForward.destinationPort,
            sshHost: sshHost,
            bindAddress: parsedForward.bindAddress,
            additionalArguments: extraArguments
        )
    }

    private static func parseForward(_ spec: String) throws -> (
        localPort: Int,
        destinationHost: String,
        destinationPort: Int,
        bindAddress: String?
    ) {
        let pattern = #"^(?:(.+):)?([0-9]+):(\[[^\]]+\]|[^:]+):([0-9]+)$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(spec.startIndex..., in: spec)
        guard let match = expression.firstMatch(in: spec, range: range), match.range == range else {
            throw ParseError.invalidForward
        }

        func value(at index: Int) -> String? {
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound, let range = Range(matchRange, in: spec) else { return nil }
            return String(spec[range])
        }

        guard
            let localText = value(at: 2),
            let localPort = Int(localText), (1...65_535).contains(localPort),
            var destinationHost = value(at: 3),
            let destinationText = value(at: 4),
            let destinationPort = Int(destinationText), (1...65_535).contains(destinationPort)
        else {
            throw ParseError.invalidForward
        }

        if destinationHost.hasPrefix("[") && destinationHost.hasSuffix("]") {
            destinationHost.removeFirst()
            destinationHost.removeLast()
        }

        return (localPort, destinationHost, destinationPort, value(at: 1))
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
