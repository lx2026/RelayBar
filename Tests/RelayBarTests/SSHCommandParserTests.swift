import XCTest
@testable import RelayBar

final class SSHCommandParserTests: XCTestCase {
    func testParsesBasicForward() throws {
        let result = try SSHCommandParser.parse("ssh -N -L 8080:localhost:3000 user@example.com")

        XCTAssertEqual(result.localPort, 8080)
        XCTAssertEqual(result.destinationHost, "localhost")
        XCTAssertEqual(result.destinationPort, 3000)
        XCTAssertEqual(result.sshHost, "user@example.com")
        XCTAssertNil(result.bindAddress)
        XCTAssertTrue(result.additionalArguments.isEmpty)
    }

    func testParsesAttachedForwardBindAndOptions() throws {
        let result = try SSHCommandParser.parse(
            "ssh -p 2222 -i ~/.ssh/work -L0.0.0.0:5432:db.internal:5432 ops@bastion"
        )

        XCTAssertEqual(result.localPort, 5432)
        XCTAssertEqual(result.destinationHost, "db.internal")
        XCTAssertEqual(result.destinationPort, 5432)
        XCTAssertEqual(result.bindAddress, "0.0.0.0")
        XCTAssertEqual(result.identityPath, "~/.ssh/work")
        XCTAssertEqual(result.additionalArguments, ["-p", "2222"])
    }

    func testParsesQuotedOption() throws {
        let result = try SSHCommandParser.parse(
            "ssh -o \"ConnectTimeout=5\" -L 9000:127.0.0.1:9001 host"
        )

        XCTAssertEqual(result.additionalArguments, ["-o", "ConnectTimeout=5"])
    }

    func testPreservesIPv6ForwardSyntax() throws {
        let result = try SSHCommandParser.parse("ssh -L 8080:[::1]:3000 host")
        let tunnel = Tunnel(
            name: "IPv6",
            localPort: result.localPort,
            destinationHost: result.destinationHost,
            destinationPort: result.destinationPort,
            sshHost: result.sshHost
        )

        XCTAssertEqual(result.destinationHost, "::1")
        XCTAssertEqual(tunnel.forwardSpec, "8080:[::1]:3000")
    }

    func testRejectsRemoteCommand() {
        XCTAssertThrowsError(try SSHCommandParser.parse("ssh -L 8080:localhost:80 host uptime")) { error in
            XCTAssertEqual(error as? SSHCommandParser.ParseError, .remoteCommand)
        }
    }

    func testRejectsDynamicForward() {
        XCTAssertThrowsError(try SSHCommandParser.parse("ssh -D 1080 host")) { error in
            XCTAssertEqual(error as? SSHCommandParser.ParseError, .unsupportedOption("-D"))
        }
    }

    func testRejectsOptionsThatCanExecuteLocalCommands() {
        XCTAssertThrowsError(
            try SSHCommandParser.parse("ssh -o 'ProxyCommand=sh -c whoami' -L 8080:localhost:80 host")
        ) { error in
            XCTAssertEqual(
                error as? SSHCommandParser.ParseError,
                .unsafeOption("-o ProxyCommand=sh -c whoami")
            )
        }
    }

    func testRejectsCustomConfigFiles() {
        XCTAssertThrowsError(try SSHCommandParser.parse("ssh -F /tmp/untrusted -L 8080:localhost:80 host")) { error in
            XCTAssertEqual(error as? SSHCommandParser.ParseError, .unsupportedOption("-F"))
        }
    }

    func testRejectsOptionShapedManualHost() {
        XCTAssertFalse(SSHArgumentPolicy.isValidHostTarget("-oProxyCommand=whoami"))
        XCTAssertFalse(SSHArgumentPolicy.isValidHostTarget("host with spaces"))
        XCTAssertTrue(SSHArgumentPolicy.isValidHostTarget("user@example.com"))
    }

    func testRejectsTamperedPersistedArguments() {
        XCTAssertFalse(SSHArgumentPolicy.areAdditionalArgumentsSafe(["-o", "LocalCommand=whoami"]))
        XCTAssertFalse(SSHArgumentPolicy.areAdditionalArgumentsSafe(["unexpected-host"]))
        XCTAssertTrue(SSHArgumentPolicy.areAdditionalArgumentsSafe(["-p", "2222", "-o", "IdentitiesOnly=yes"]))
    }
}
