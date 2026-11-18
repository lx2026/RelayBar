import Foundation

enum SSHArgumentPolicy {
    static let allowedFlags: Set<String> = ["-4", "-6", "-a", "-C", "-k", "-q", "-v", "-vv", "-vvv"]
    static let optionsWithValues: Set<String> = ["-J", "-i", "-l", "-o", "-p"]
    static let attachedOptionPrefixes = ["-J", "-i", "-l", "-o", "-p"]

    private static let allowedOpenSSHOptions: Set<String> = [
        "addressfamily",
        "batchmode",
        "compression",
        "connectionattempts",
        "connecttimeout",
        "hostkeyalgorithms",
        "identitiesonly",
        "ipqos",
        "kexalgorithms",
        "loglevel",
        "macs",
        "passwordauthentication",
        "port",
        "preferredauthentications",
        "proxyjump",
        "pubkeyauthentication",
        "serveralivecountmax",
        "serveraliveinterval",
        "stricthostkeychecking",
        "tcpkeepalive",
        "user",
        "verifyhostkeydns"
    ]

    static func isValidHostTarget(_ value: String) -> Bool {
        let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasPrefix("-") else { return false }
        return !target.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }
    }

    static func isValidDestinationHost(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.hasPrefix("-") else { return false }
        return !host.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }
    }

    static func isValidBindAddress(_ value: String?) -> Bool {
        guard let value else { return true }
        if value.isEmpty { return true }
        let address = SSHForwardingFormat.unbracket(value)
        guard !address.isEmpty, !address.hasPrefix("-") else { return false }
        return !address.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }
    }

    static func isValidSocketPath(_ value: String) -> Bool {
        guard
            value.hasPrefix("/"),
            value.utf8.count <= 1_024,
            !value.contains(":"),
            value != "/"
        else {
            return false
        }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0)
        }
    }

    private static let permitRemoteOpenExpression = try? NSRegularExpression(
        pattern: #"^(\*|[^:\s]+|\[[^\]]+\]):(\*|[0-9]+)$"#
    )

    static func isValidPermitRemoteOpenDestination(_ value: String) -> Bool {
        guard isSafeOptionValue(value) else { return false }
        guard
            let expression = permitRemoteOpenExpression,
            expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            )?.range == NSRange(value.startIndex..., in: value)
        else {
            return false
        }

        guard let separator = value.lastIndex(of: ":") else { return false }
        let port = value[value.index(after: separator)...]
        if port == "*" { return true }
        guard let number = Int(port) else { return false }
        return (1...65_535).contains(number)
    }

    static func isSafeOpenSSHOption(_ value: String) -> Bool {
        guard let (key, _) = splitOpenSSHOption(value) else { return false }
        return allowedOpenSSHOptions.contains(key.lowercased())
    }

    static func splitOpenSSHOption(_ value: String) -> (key: String, value: String)? {
        guard isSafeOptionValue(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyEnd = trimmed.firstIndex(where: { character in
            character == "=" || character.isWhitespace
        }) else {
            return nil
        }
        let key = String(trimmed[..<keyEnd])
        let optionValue = trimmed[keyEnd...]
            .drop(while: { $0 == "=" || $0.isWhitespace })
        guard !key.isEmpty, !optionValue.isEmpty else { return nil }
        return (key, String(optionValue))
    }

    static func areAdditionalArgumentsSafe(_ arguments: [String]) -> Bool {
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            if allowedFlags.contains(argument) {
                index += 1
                continue
            }

            if optionsWithValues.contains(argument) {
                index += 1
                guard index < arguments.count else { return false }
                let value = arguments[index]
                guard isSafeOptionValue(value) else { return false }
                if argument == "-o", !isSafeOpenSSHOption(value) { return false }
                index += 1
                continue
            }

            guard argument.hasPrefix("-") else { return false }
            guard let prefix = attachedOptionPrefixes.first(where: {
                argument.hasPrefix($0) && argument.count > $0.count
            }) else { return false }

            let value = String(argument.dropFirst(prefix.count))
            guard isSafeOptionValue(value) else { return false }
            if prefix == "-o" {
                guard isSafeOpenSSHOption(value) else { return false }
            }
            index += 1
        }

        return true
    }

    static func isSafeOptionValue(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
            }
    }
}
