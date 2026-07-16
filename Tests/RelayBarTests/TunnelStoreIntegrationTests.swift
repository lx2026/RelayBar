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
            case .starting, .stopped:
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
}
