import Foundation
import XCTest
@testable import RelayBar

@MainActor
final class TunnelStoreIntegrationTests: XCTestCase {
    func testConfiguredTunnelWhenLiveTestingIsEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["RELAYBAR_LIVE_TEST"] == "1",
            let sshHost = environment["RELAYBAR_LIVE_SSH_HOST"],
            !sshHost.isEmpty
        else {
            throw XCTSkip("Set RELAYBAR_LIVE_TEST=1 and RELAYBAR_LIVE_SSH_HOST to run the live test.")
        }

        let suiteName = "RelayBarTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated preferences.")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TunnelStore(defaults: defaults)
        let tunnel = Tunnel(
            name: "Spark",
            localPort: 3000,
            destinationHost: "127.0.0.1",
            destinationPort: 3000,
            sshHost: sshHost
        )

        store.start(tunnel)
        defer { store.stop(tunnel) }

        var reachedRunningState = false
        var lastConnectionError: Error?

        for _ in 0..<60 {
            switch store.phase(for: tunnel) {
            case .running:
                reachedRunningState = true
                var request = URLRequest(url: URL(string: "http://127.0.0.1:3000/")!)
                request.timeoutInterval = 1
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                    XCTAssertFalse(data.isEmpty)
                    return
                } catch {
                    lastConnectionError = error
                }
            case .failed(let message):
                XCTFail(message)
                return
            case .starting, .retrying, .stopped:
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        if reachedRunningState {
            XCTFail("Tunnel process ran, but the forwarded endpoint was not reachable: \(lastConnectionError?.localizedDescription ?? "unknown error")")
        } else {
            XCTFail("Tunnel did not reach the running state.")
        }
    }

    func testUnexpectedExitRetriesUntilLimit() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TunnelStore(
            defaults: defaults,
            sshExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
            maxRetryAttempts: 2,
            retryDelayProvider: { _ in 0.01 }
        )
        let tunnel = makeTunnel()
        store.add(tunnel)

        store.start(tunnel)

        for _ in 0..<200 {
            if case .failed(let message) = store.phase(for: tunnel) {
                XCTAssertTrue(message.contains("Automatic retry stopped after 2 attempts."))
                XCTAssertEqual(store.runningCount, 0)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTFail("Tunnel did not stop retrying after the configured limit.")
    }

    func testManualStopCancelsPendingRetry() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TunnelStore(
            defaults: defaults,
            sshExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
            retryDelayProvider: { _ in 0.2 }
        )
        let tunnel = makeTunnel()
        store.add(tunnel)
        store.start(tunnel)

        for _ in 0..<100 {
            if case .retrying = store.phase(for: tunnel) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        guard case .retrying = store.phase(for: tunnel) else {
            XCTFail("Tunnel did not enter retry backoff.")
            return
        }

        store.stop(tunnel)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.phase(for: tunnel), .stopped)
        XCTAssertEqual(store.runningCount, 0)
    }

    func testRetryDelayUsesExponentialBackoffWithCap() {
        XCTAssertEqual(TunnelStore.retryDelay(for: 1), 1)
        XCTAssertEqual(TunnelStore.retryDelay(for: 2), 2)
        XCTAssertEqual(TunnelStore.retryDelay(for: 3), 4)
        XCTAssertEqual(TunnelStore.retryDelay(for: 6), 32)
        XCTAssertEqual(TunnelStore.retryDelay(for: 7), 60)
        XCTAssertEqual(TunnelStore.retryDelay(for: 10), 60)
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "RelayBarTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeTunnel() -> Tunnel {
        Tunnel(
            name: "Retry test",
            localPort: 43_210,
            destinationHost: "127.0.0.1",
            destinationPort: 80,
            sshHost: "example.com"
        )
    }
}
