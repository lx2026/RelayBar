import XCTest
@testable import RelayBar

final class PresentationTests: XCTestCase {
    func testCompactSummaryOmitsDefaultLocalhostWithoutChangingSSHOrCopyValues() {
        let rule = ForwardingRule(
            kind: .local, listen: .tcp(bindAddress: "localhost", port: 8000),
            destination: .tcp(host: "db", port: 5432)
        )
        XCTAssertEqual(rule.compactDisplaySummary(runtimePort: nil), ":8000 → db:5432")
        XCTAssertEqual(rule.specification, "localhost:8000:db:5432")
        XCTAssertEqual(rule.copyableListenEndpoint(runtimePort: nil), "localhost:8000")
        var loopback = rule
        loopback.destination = .tcp(host: "localhost", port: 5432)
        XCTAssertEqual(loopback.compactDisplaySummary(runtimePort: nil), ":8000 → :5432")
    }

    func testCompactSummaryPreservesExplicitBindingsIPv6AndRuntimePorts() {
        let rule = ForwardingRule(
            kind: .remote, listen: .tcp(bindAddress: "::", port: 0),
            destination: .tcp(host: "::1", port: 5432)
        )
        XCTAssertEqual(rule.compactDisplaySummary(runtimePort: 47001), "[::]:47001 ⇠ [::1]:5432")
        XCTAssertEqual(rule.specification, "[::]:0:[::1]:5432")
        let exposed = ForwardingRule(
            kind: .localDynamic, listen: .tcp(bindAddress: "0.0.0.0", port: 1080)
        )
        XCTAssertEqual(exposed.compactDisplaySummary(runtimePort: nil), "0.0.0.0:1080 → SOCKS via server")
    }

    func testRuleValidationExplainsMissingAndInvalidPorts() {
        var draft = ForwardingRuleDraft(kind: .local)
        XCTAssertEqual(draft.validationMessage, "Enter a listening port in Forwarding Rules.")
        draft.listenPort = "8000"
        XCTAssertEqual(draft.validationMessage, "Enter a destination port in Forwarding Rules.")
        draft.destinationPort = "65536"
        XCTAssertEqual(draft.validationMessage, "Use a destination port from 1 to 65535.")
        draft.destinationPort = "5432"
        XCTAssertNil(draft.validationMessage)
        XCTAssertNotNil(draft.forwardingRule)
        draft.listenPort = "0"
        XCTAssertEqual(draft.validationMessage, "Use a listening port from 1 to 65535.")
        draft.kind = .remote
        XCTAssertNil(draft.validationMessage)
    }

    func testRuleValidationCoversSOCKSAndUnixPaths() {
        var draft = ForwardingRuleDraft(kind: .remoteDynamic)
        draft.listenPort = "0"
        XCTAssertNil(draft.validationMessage)
        draft.listenKind = .unix
        XCTAssertEqual(draft.validationMessage, "SOCKS needs a TCP listener.")
        draft.kind = .local
        XCTAssertEqual(draft.validationMessage, "Enter an absolute listening socket path.")
        draft.listenPath = "/tmp/listener.sock"
        draft.destinationKind = .unix
        draft.destinationPath = "relative.sock"
        XCTAssertEqual(draft.validationMessage, "Enter an absolute destination socket path.")
        draft.destinationPath = "/tmp/target.sock"
        XCTAssertNil(draft.validationMessage)
        XCTAssertNotNil(draft.forwardingRule)
    }
}
