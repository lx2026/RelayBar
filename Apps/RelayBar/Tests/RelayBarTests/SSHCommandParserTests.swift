import XCTest
@testable import RelayBar

final class SSHCommandParserTests: XCTestCase {
    func testParsesBasicLocalForwardAndNormalizesLoopback() throws {
        let result = try SSHCommandParser.parse(
            "ssh -N -L 8080:localhost:3000 user@example.com"
        )

        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules[0].kind, .local)
        XCTAssertEqual(result.rules[0].listen, .tcp(bindAddress: "localhost", port: 8080))
        XCTAssertEqual(result.rules[0].destination, .tcp(host: "localhost", port: 3000))
        XCTAssertEqual(result.sshHost, "user@example.com")
        XCTAssertTrue(result.additionalArguments.isEmpty)
    }

    func testImportsRequestedDynamicSOCKSCommandAndSSHPort() throws {
        let result = try SSHCommandParser.parse(
            "ssh -N -D 9999 -p 1234 user@server"
        )

        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules[0].kind, .localDynamic)
        XCTAssertEqual(result.rules[0].listen, .tcp(bindAddress: "localhost", port: 9999))
        XCTAssertNil(result.rules[0].destination)
        XCTAssertEqual(result.additionalArguments, ["-p", "1234"])
    }

    func testImportsReverseSOCKSWithExplicitDefaultPolicy() throws {
        let result = try SSHCommandParser.parse("ssh -N -R 1081 server")

        XCTAssertEqual(result.rules[0].kind, .remoteDynamic)
        XCTAssertEqual(result.rules[0].listen, .tcp(bindAddress: "localhost", port: 1081))
        XCTAssertEqual(result.reverseSOCKSPolicy, .any)
    }

    func testImportsMixedRepeatedRulesInOrder() throws {
        let result = try SSHCommandParser.parse(
            "ssh -L8080:web:80 -D 1080 -R9000:localhost:9001 -L 8443:web:443 host"
        )

        XCTAssertEqual(result.rules.map(\.kind), [.local, .localDynamic, .remote, .local])
        XCTAssertEqual(
            result.rules.map(\.specification),
            [
                "localhost:8080:web:80",
                "localhost:1080",
                "localhost:9000:localhost:9001",
                "localhost:8443:web:443"
            ]
        )
    }

    func testParsesAllFixedTCPAndUnixCombinations() throws {
        let cases: [(String, ForwardingRuleKind, String)] = [
            ("-L 8080:db:5432", .local, "localhost:8080:db:5432"),
            ("-L 8080:/var/run/db.sock", .local, "localhost:8080:/var/run/db.sock"),
            ("-L /tmp/local.sock:db:5432", .local, "/tmp/local.sock:db:5432"),
            (
                "-L /tmp/local.sock:/var/run/db.sock",
                .local,
                "/tmp/local.sock:/var/run/db.sock"
            ),
            ("-R 8080:db:5432", .remote, "localhost:8080:db:5432"),
            ("-R 8080:/tmp/local.sock", .remote, "localhost:8080:/tmp/local.sock"),
            ("-R /tmp/remote.sock:db:5432", .remote, "/tmp/remote.sock:db:5432"),
            (
                "-R /tmp/remote.sock:/tmp/local.sock",
                .remote,
                "/tmp/remote.sock:/tmp/local.sock"
            )
        ]

        for (forward, kind, expectedSpecification) in cases {
            let result = try SSHCommandParser.parse("ssh \(forward) server")
            XCTAssertEqual(result.rules[0].kind, kind, forward)
            XCTAssertEqual(
                result.rules[0].specification,
                expectedSpecification,
                forward
            )
        }
    }

    func testParsesQuotedUnixSocketPathsWithSpaces() throws {
        let result = try SSHCommandParser.parse(
            "ssh -L '/tmp/local socket:/tmp/remote socket' server"
        )

        XCTAssertEqual(result.rules[0].listen, .unix(path: "/tmp/local socket"))
        XCTAssertEqual(
            result.rules[0].destination,
            .unix(path: "/tmp/remote socket")
        )
    }

    func testPreservesIPv6ListenAndDestinationSyntax() throws {
        let result = try SSHCommandParser.parse(
            "ssh -L [::1]:8080:[2001:db8::10]:3000 host"
        )

        XCTAssertEqual(result.rules[0].listen, .tcp(bindAddress: "::1", port: 8080))
        XCTAssertEqual(
            result.rules[0].destination,
            .tcp(host: "2001:db8::10", port: 3000)
        )
        XCTAssertEqual(
            result.rules[0].specification,
            "[::1]:8080:[2001:db8::10]:3000"
        )
    }

    func testSupportsAutomaticRemotePortsForFixedAndDynamicRules() throws {
        let result = try SSHCommandParser.parse(
            "ssh -R 0:localhost:3000 -R 0 server"
        )

        XCTAssertEqual(result.rules.map(\.kind), [.remote, .remoteDynamic])
        XCTAssertEqual(result.rules[0].listen.tcp?.port, 0)
        XCTAssertEqual(result.rules[1].listen.tcp?.port, 0)
        XCTAssertThrowsError(
            try SSHCommandParser.parse("ssh -L 0:localhost:3000 server")
        )
        XCTAssertThrowsError(
            try SSHCommandParser.parse("ssh -D 0 server")
        )
    }

    func testParsesStructuredUnixAndReverseSOCKSOptions() throws {
        let result = try SSHCommandParser.parse(
            """
            ssh -o 'PermitRemoteOpen=example.com:443 *.internal:8443' \
            -o StreamLocalBindMask=0077 -o StreamLocalBindUnlink=yes \
            -R 1081 server
            """
        )

        XCTAssertEqual(
            result.reverseSOCKSPolicy,
            .allow(["example.com:443", "*.internal:8443"])
        )
        XCTAssertEqual(result.streamLocalSettings.bindMask, 0o077)
        XCTAssertTrue(result.streamLocalSettings.unlinkStaleSocket)
        XCTAssertTrue(result.additionalArguments.isEmpty)
    }

    func testPreservesAllowedConnectionOptions() throws {
        let result = try SSHCommandParser.parse(
            "ssh -p 2222 -i ~/.ssh/work -J jump -o 'ConnectTimeout=5' -D1080 host"
        )

        XCTAssertEqual(
            result.additionalArguments,
            [
                "-p", "2222",
                "-i", "~/.ssh/work",
                "-J", "jump",
                "-o", "ConnectTimeout=5"
            ]
        )
    }

    func testRejectsMalformedOrAmbiguousForwardingCommands() {
        let commands = [
            "ssh host",
            "ssh -D server",
            "ssh -L 8080:localhost server",
            "ssh -R /tmp/socket server",
            "ssh -D 1080 host uptime",
            "ssh -D 1080 host another-host",
            "ssh -L relative.sock:/tmp/remote.sock host",
            "ssh -L /tmp/a:colon.sock:/tmp/remote.sock host",
            "ssh -D [::1:1080 host"
        ]

        for command in commands {
            XCTAssertThrowsError(try SSHCommandParser.parse(command), command)
        }
    }

    func testRejectsUnsafeOrConflictingOptions() {
        let commands = [
            "ssh -o 'ProxyCommand=sh -c whoami' -D 1080 host",
            "ssh -F /tmp/untrusted -D 1080 host",
            "ssh -o StreamLocalBindMask=0888 -D 1080 host",
            "ssh -o StreamLocalBindUnlink=maybe -D 1080 host",
            "ssh -o PermitRemoteOpen=bad -R 1080 host",
            "ssh -o PermitRemoteOpen=any -o PermitRemoteOpen=none -R 1080 host"
        ]

        for command in commands {
            XCTAssertThrowsError(try SSHCommandParser.parse(command), command)
        }
    }

    func testRejectsControlCharactersAndOptionShapedValues() {
        XCTAssertFalse(SSHArgumentPolicy.isValidHostTarget("-oProxyCommand=whoami"))
        XCTAssertFalse(SSHArgumentPolicy.isValidHostTarget("host with spaces"))
        XCTAssertTrue(SSHArgumentPolicy.isValidHostTarget("user@example.com"))
        XCTAssertFalse(SSHArgumentPolicy.isValidSocketPath("/tmp/bad\u{0000}socket"))
        XCTAssertFalse(SSHArgumentPolicy.isValidSocketPath("relative/socket"))
        XCTAssertFalse(
            SSHArgumentPolicy.areAdditionalArgumentsSafe([
                "-o", "User=alice\nProxyCommand=whoami"
            ])
        )
        XCTAssertFalse(SSHArgumentPolicy.areAdditionalArgumentsSafe(["unexpected-host"]))
    }
}

final class TunnelTests: XCTestCase {
    func testLegacyJSONMigratesToOneTypedLocalRule() throws {
        let legacy = LegacyTunnel(
            id: UUID(),
            name: "Database",
            localPort: 5432,
            destinationHost: "db.internal",
            destinationPort: 5432,
            sshHost: "bastion",
            bindAddress: "127.0.0.1",
            additionalArguments: ["-p", "2222"]
        )

        let tunnel = try JSONDecoder().decode(
            Tunnel.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(tunnel.id, legacy.id)
        XCTAssertEqual(tunnel.name, legacy.name)
        XCTAssertEqual(tunnel.sshHost, legacy.sshHost)
        XCTAssertEqual(tunnel.additionalArguments, legacy.additionalArguments)
        XCTAssertNil(tunnel.groupTag)
        XCTAssertEqual(tunnel.rules.count, 1)
        XCTAssertEqual(tunnel.rules[0].kind, .local)
        XCTAssertEqual(tunnel.rules[0].listen, .tcp(bindAddress: "127.0.0.1", port: 5432))
        XCTAssertEqual(
            tunnel.rules[0].destination,
            .tcp(host: "db.internal", port: 5432)
        )
    }

    func testNewJSONUsesTypedRulesInsteadOfLegacyDestinationFields() throws {
        var tunnel = makeTunnel(bindAddress: "localhost")
        tunnel.groupTag = "Work"
        let data = try JSONEncoder().encode(tunnel)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNotNil(object["rules"])
        XCTAssertEqual(object["groupTag"] as? String, "Work")
        XCTAssertNil(object["localPort"])
        XCTAssertNil(object["destinationHost"])
    }

    func testGroupTagValidationNormalizesAndBoundsUserVisibleCharacters() {
        XCTAssertEqual(
            TunnelGroupTag.validate("  Client   Projects  "),
            .valid("Client Projects")
        )
        XCTAssertEqual(TunnelGroupTag.validate("   "), .ungrouped)
        XCTAssertEqual(
            TunnelGroupTag.validate(String(repeating: "🙂", count: 32)),
            .valid(String(repeating: "🙂", count: 32))
        )
        XCTAssertNotNil(
            TunnelGroupTag.validate(
                String(repeating: "🙂", count: 33)
            ).errorMessage
        )
        XCTAssertNotNil(TunnelGroupTag.validate("Work\nPersonal").errorMessage)
        XCTAssertNotNil(TunnelGroupTag.validate("Work\tPersonal").errorMessage)
    }

    func testGroupTagMatchingReusesExistingSpellingWithoutLocaleDependence() {
        XCTAssertEqual(
            TunnelGroupTag.resolve(
                "  work ",
                existingNames: ["Personal", "Work"]
            ),
            .valid("Work")
        )
        XCTAssertEqual(
            TunnelGroupTag.canonicalKey("WORK"),
            TunnelGroupTag.canonicalKey("work")
        )
    }

    func testLegacyForwardingRecordPreservesAnAlreadyAddedGroupTag() throws {
        let legacy = TaggedLegacyTunnel(
            id: UUID(),
            name: "Database",
            localPort: 5_432,
            destinationHost: "db.internal",
            destinationPort: 5_432,
            sshHost: "bastion",
            bindAddress: "127.0.0.1",
            additionalArguments: ["-p", "2222"],
            groupTag: "  Production   Access "
        )

        let tunnel = try JSONDecoder().decode(
            Tunnel.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(tunnel.groupTag, "Production Access")
        XCTAssertEqual(tunnel.rules.count, 1)
        XCTAssertEqual(tunnel.id, legacy.id)
    }

    func testInvalidPersistedGroupTagFailsClosed() throws {
        let tunnel = makeTunnel(bindAddress: "localhost")
        let data = try JSONEncoder().encode(tunnel)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["groupTag"] = "Work\nInjected"

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Tunnel.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testBrowserURLUsesTypeCorrectLocalTCPRule() {
        XCTAssertEqual(
            makeTunnel(bindAddress: nil).unambiguousBrowserURL?.absoluteString,
            "http://localhost:8080/"
        )
        XCTAssertEqual(
            makeTunnel(bindAddress: "0.0.0.0").unambiguousBrowserURL?.host,
            "localhost"
        )
        XCTAssertEqual(
            makeTunnel(bindAddress: "::").unambiguousBrowserURL?.host,
            "localhost"
        )
        XCTAssertEqual(
            makeTunnel(bindAddress: "[::1]").unambiguousBrowserURL?.absoluteString,
            "http://[::1]:8080/"
        )

        let socks = Tunnel(
            name: "SOCKS",
            sshHost: "example.com",
            rules: [
                ForwardingRule(
                    kind: .localDynamic,
                    listen: .tcp(bindAddress: "localhost", port: 1080)
                )
            ]
        )
        XCTAssertNil(socks.unambiguousBrowserURL)
    }

    func testRejectsConflictingListenersAndMissingReversePolicy() {
        let first = ForwardingRule(
            kind: .localDynamic,
            listen: .tcp(bindAddress: "localhost", port: 1080)
        )
        let second = ForwardingRule.localTCP(
            bindAddress: "127.0.0.1",
            port: 1080,
            destinationHost: "localhost",
            destinationPort: 80
        )
        XCTAssertFalse(
            Tunnel(
                name: "Conflict",
                sshHost: "host",
                rules: [first, second]
            ).isSafeToRun
        )

        let reverse = ForwardingRule(
            kind: .remoteDynamic,
            listen: .tcp(bindAddress: "localhost", port: 1081)
        )
        XCTAssertFalse(
            Tunnel(name: "Reverse", sshHost: "host", rules: [reverse]).isSafeToRun
        )
        XCTAssertTrue(
            Tunnel(
                name: "Reverse",
                sshHost: "host",
                rules: [reverse],
                reverseSOCKSPolicy: .allow(["example.com:443"])
            ).isSafeToRun
        )
    }

    func testRuntimePortAppearsOnlyInResolvedSummary() {
        let rule = ForwardingRule(
            kind: .remote,
            listen: .tcp(bindAddress: "localhost", port: 0),
            destination: .tcp(host: "localhost", port: 3000)
        )

        XCTAssertTrue(rule.displaySummary.contains(":0"))
        XCTAssertTrue(rule.displaySummary(runtimePort: 47_000).contains(":47000"))
        XCTAssertNil(rule.copyableListenEndpoint(runtimePort: nil))
        XCTAssertEqual(
            rule.copyableListenEndpoint(runtimePort: 47_000),
            "localhost:47000"
        )
    }

    func testMixedProfileRoundTripsWithoutChangingRuleMeaning() throws {
        let profile = Tunnel(
            name: "Mixed",
            sshHost: "user@server",
            additionalArguments: ["-p", "2222"],
            rules: [
                .localTCP(
                    bindAddress: "localhost",
                    port: 8_080,
                    destinationHost: "web.internal",
                    destinationPort: 80
                ),
                ForwardingRule(
                    kind: .localDynamic,
                    listen: .tcp(bindAddress: "::1", port: 1_080)
                ),
                ForwardingRule(
                    kind: .remote,
                    listen: .unix(path: "/tmp/remote.sock"),
                    destination: .unix(path: "/tmp/local.sock")
                ),
                ForwardingRule(
                    kind: .remoteDynamic,
                    listen: .tcp(bindAddress: "localhost", port: 0)
                )
            ],
            reverseSOCKSPolicy: .allow(["example.com:443"]),
            streamLocalSettings: StreamLocalSettings(
                bindMask: 0o077,
                unlinkStaleSocket: true
            )
        )

        let decoded = try JSONDecoder().decode(
            Tunnel.self,
            from: JSONEncoder().encode(profile)
        )

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(
            decoded.rules.flatMap(\.sshArguments),
            profile.rules.flatMap(\.sshArguments)
        )
        XCTAssertTrue(decoded.isSafeToRun)
    }

    func testRejectsDuplicateRuleIdentityAndTamperedOptions() {
        let rule = ForwardingRule(
            kind: .localDynamic,
            listen: .tcp(bindAddress: "localhost", port: 1_080)
        )
        XCTAssertFalse(
            Tunnel(
                name: "Duplicate IDs",
                sshHost: "server",
                rules: [rule, rule]
            ).isSafeToRun
        )
        XCTAssertFalse(
            Tunnel(
                name: "Tampered",
                sshHost: "server",
                additionalArguments: ["-o", "ProxyCommand=whoami"],
                rules: [rule]
            ).isSafeToRun
        )
    }

    func testReverseSOCKSSummaryAlwaysShowsDestinationPolicy() {
        let rule = ForwardingRule(
            kind: .remoteDynamic,
            listen: .tcp(bindAddress: "localhost", port: 1_081)
        )
        let profile = Tunnel(
            name: "Reverse",
            sshHost: "server",
            rules: [rule],
            reverseSOCKSPolicy: .any
        )

        XCTAssertTrue(profile.displaySummary.contains("Any destination"))
    }

    private func makeTunnel(bindAddress: String?) -> Tunnel {
        Tunnel(
            name: "Web",
            localPort: 8080,
            destinationHost: "127.0.0.1",
            destinationPort: 3000,
            sshHost: "example.com",
            bindAddress: bindAddress
        )
    }
}

final class TunnelGroupingTests: XCTestCase {
    func testAllUngroupedProfilesKeepOneFlatOrderedBucket() {
        let first = makeTunnel(name: "First")
        let second = makeTunnel(name: "Second")

        let grouping = TunnelGrouping(tunnels: [first, second])

        XCTAssertFalse(grouping.isGrouped)
        XCTAssertEqual(grouping.groupNames, [])
        XCTAssertEqual(grouping.sections.count, 1)
        XCTAssertEqual(grouping.sections[0].id, .ungrouped)
        XCTAssertEqual(grouping.sections[0].tunnels.map(\.id), [first.id, second.id])
    }

    func testNamedBucketsSortAndKeepUngroupedLastWithoutDuplicatingProfiles() {
        let ungrouped = makeTunnel(name: "Scratch")
        let workFirst = makeTunnel(name: "Dashboard", groupTag: "Work")
        let personal = makeTunnel(name: "Photos", groupTag: "Personal")
        let workSecond = makeTunnel(name: "Desktop", groupTag: "work")

        let grouping = TunnelGrouping(
            tunnels: [ungrouped, workFirst, personal, workSecond]
        )

        XCTAssertTrue(grouping.isGrouped)
        XCTAssertEqual(
            grouping.sections.map(\.displayName),
            ["Personal", "Work", "Ungrouped"]
        )
        XCTAssertEqual(
            grouping.sections[1].tunnels.map(\.id),
            [workFirst.id, workSecond.id]
        )
        let renderedIDs = grouping.sections.flatMap { $0.tunnels.map(\.id) }
        XCTAssertEqual(renderedIDs.count, 4)
        XCTAssertEqual(Set(renderedIDs).count, 4)
        XCTAssertEqual(Set(renderedIDs), Set([
            ungrouped.id, workFirst.id, personal.id, workSecond.id
        ]))
    }

    func testOneNamedBucketStillEnablesGroupedPresentation() {
        let first = makeTunnel(name: "One", groupTag: "Work")
        let second = makeTunnel(name: "Two", groupTag: "Work")

        let grouping = TunnelGrouping(tunnels: [first, second])

        XCTAssertTrue(grouping.isGrouped)
        XCTAssertEqual(grouping.sections.map(\.displayName), ["Work"])
        XCTAssertEqual(grouping.sections[0].tunnels.map(\.id), [first.id, second.id])
    }

    private func makeTunnel(
        name: String,
        groupTag: String? = nil
    ) -> Tunnel {
        Tunnel(
            name: name,
            localPort: 8_000 + name.count,
            destinationHost: "localhost",
            destinationPort: 80,
            sshHost: "server",
            groupTag: groupTag
        )
    }
}

private struct LegacyTunnel: Codable {
    let id: UUID
    let name: String
    let localPort: Int
    let destinationHost: String
    let destinationPort: Int
    let sshHost: String
    let bindAddress: String?
    let additionalArguments: [String]
}

private struct TaggedLegacyTunnel: Codable {
    let id: UUID
    let name: String
    let localPort: Int
    let destinationHost: String
    let destinationPort: Int
    let sshHost: String
    let bindAddress: String?
    let additionalArguments: [String]
    let groupTag: String?
}
