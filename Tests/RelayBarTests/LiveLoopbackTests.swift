// Exercises the real /usr/bin/ssh and /usr/bin/sftp paths against a throwaway
// loopback sshd. Skipped unless RELAYBAR_LOOPBACK_SSH_DIR points at that setup.
import Foundation
import XCTest
@testable import RelayBar

@MainActor
final class LiveLoopbackTests: XCTestCase {
    private var fixtureDirectory: String {
        get throws {
            let value = ProcessInfo.processInfo.environment["RELAYBAR_LOOPBACK_SSH_DIR"]
            try XCTSkipIf(value == nil, "Set RELAYBAR_LOOPBACK_SSH_DIR to run.")
            return value!
        }
    }

    private func makeArguments() throws -> [String] {
        [
            "-p", "2222",
            "-i", "\(try fixtureDirectory)/home/.ssh/id_ed25519",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=no"
        ]
    }

    /// Real control socket, real `-O forward`, real data through the forward,
    /// and a real allocated remote port. Then stop and immediately restart,
    /// which is the Task 007 path against genuine OpenSSH timing.
    func testInstallsRulesCarriesTrafficAndRestartsAgainstRealSSH() async throws {
        let arguments = try makeArguments()
        let suiteName = "RelayBarLoopback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TunnelStore(
            defaults: defaults,
            maxRetryAttempts: 2,
            retryDelayProvider: { _ in 0.2 }
        )
        let forward = ForwardingRule(
            kind: .local,
            listen: .tcp(bindAddress: "localhost", port: 9_876),
            destination: .tcp(host: "127.0.0.1", port: 8_765)
        )
        let allocated = ForwardingRule(
            kind: .remote,
            listen: .tcp(bindAddress: "localhost", port: 0),
            destination: .tcp(host: "127.0.0.1", port: 8_765)
        )
        let profile = Tunnel(
            name: "Loopback",
            sshHost: "127.0.0.1",
            additionalArguments: arguments,
            rules: [forward, allocated]
        )
        XCTAssertTrue(profile.isSafeToRun)

        store.start(profile)
        defer { store.stop(profile) }
        let started = await waitUntil { store.phase(for: profile) == .running }
        XCTAssertTrue(started, "did not reach running: \(store.phase(for: profile))")

        // OpenSSH reported a real allocated port for the port-0 remote rule.
        let runtimePort = store.runtimePorts(for: profile)[allocated.id]
        XCTAssertNotNil(runtimePort)
        XCTAssertTrue((1...65_535).contains(runtimePort ?? 0))

        // Real bytes through the real forward.
        var request = URLRequest(url: URL(string: "http://localhost:9876/")!)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("relaybar-live-ok"))

        // Task 007: stop, then start again immediately.
        store.stop(profile)
        XCTAssertEqual(store.phase(for: profile), .stopped)
        store.start(profile)
        let restarted = await waitUntil { store.phase(for: profile) == .running }
        XCTAssertTrue(restarted, "restart failed: \(store.phase(for: profile))")
        if case .failed(let message) = store.phase(for: profile) {
            XCTFail("restart reported: \(message)")
        }

        // The restarted launch allocated its own port and still carries traffic.
        XCTAssertNotNil(store.runtimePorts(for: profile)[allocated.id])
        let (secondData, secondResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(
            String(decoding: secondData, as: UTF8.self).contains("relaybar-live-ok")
        )
    }

    /// Against a real server: entries whose names hold glob metacharacters list
    /// correctly and can be opened, because sftp's quoting matches them
    /// literally. This is the evidence that reverted the Task 005 refusal.
    func testListsAndOpensRealGlobNamedEntries() async throws {
        let directory = try fixtureDirectory
        let service = SFTPRemoteFileService()
        let server = RemoteServer(
            id: UUID(),
            name: "loopback",
            sshHost: "127.0.0.1",
            additionalArguments: try makeArguments()
        )

        let entries = try await service.list(server: server, path: "\(directory)/files")
        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("plain.md"), "got \(names)")
        XCTAssertTrue(names.contains("report[2026]"), "glob-named row must survive listing")
        XCTAssertTrue(names.contains("draft?.md"), "glob-named row must survive listing")

        // The bracketed directory opens: sftp matched it literally rather than
        // treating [2026] as a character class.
        let bracketed = try await service.list(
            server: server,
            path: "\(directory)/files/report[2026]"
        )
        XCTAssertTrue(bracketed.isEmpty, "expected the fixture directory to be empty")

        // A star in a directory name is likewise literal, not a wildcard.
        let starred = try await service.list(
            server: server,
            path: "\(directory)/files/star*dir"
        )
        XCTAssertTrue(starred.isEmpty, "expected the fixture directory to be empty")

        // A plain path still round-trips through real sftp.
        let parent = try await service.list(server: server, path: directory)
        XCTAssertTrue(parent.contains { $0.name == "files" && $0.isDirectory })
    }

    private func waitUntil(
        timeoutIterations: Int = 300,
        condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
