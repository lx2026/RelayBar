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
            throw XCTSkip(
                "Set RELAYBAR_LIVE_TEST=1 and RELAYBAR_LIVE_SSH_HOST to run the live test."
            )
        }

        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TunnelStore(defaults: defaults)
        let tunnel = Tunnel(
            name: "Live local forward",
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
                var request = URLRequest(
                    url: URL(string: "http://127.0.0.1:3000/")!
                )
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
            XCTFail(
                "The forward ran but was unreachable: "
                    + (lastConnectionError?.localizedDescription ?? "unknown error")
            )
        } else {
            XCTFail("The forwarding profile did not reach the running state.")
        }
    }

    func testConfiguredLocalUnixSocketWhenFlexibleLiveTestingIsEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["RELAYBAR_FLEXIBLE_LIVE_TEST"] == "1",
            let sshHost = environment["RELAYBAR_LIVE_SSH_HOST"],
            !sshHost.isEmpty
        else {
            throw XCTSkip(
                "Set RELAYBAR_FLEXIBLE_LIVE_TEST=1 and RELAYBAR_LIVE_SSH_HOST to run the flexible live test."
            )
        }

        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "RelayBarLiveUnix-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketURL = directory.appendingPathComponent("listener.sock")
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TunnelStore(defaults: defaults)
        let profile = Tunnel(
            name: "Live local Unix",
            sshHost: sshHost,
            rules: [
                ForwardingRule(
                    kind: .local,
                    listen: .unix(path: socketURL.path),
                    destination: .tcp(host: "127.0.0.1", port: 9)
                )
            ],
            streamLocalSettings: StreamLocalSettings(
                bindMask: 0o077,
                unlinkStaleSocket: true
            )
        )

        store.start(profile)
        let startupFinished = await waitUntil(timeoutIterations: 2_000) {
            switch store.phase(for: profile) {
            case .running, .failed:
                true
            case .stopped, .starting, .retrying:
                false
            }
        }
        guard startupFinished, store.phase(for: profile) == .running else {
            return XCTFail(
                "The local Unix profile did not run: \(store.phase(for: profile))"
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: socketURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )

        store.stop(profile)

        XCTAssertEqual(store.phase(for: profile), .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testMigratesLegacyCollectionTransactionallyToV2() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = LegacyTunnel(
            id: UUID(),
            name: "Legacy",
            localPort: 8080,
            destinationHost: "localhost",
            destinationPort: 3000,
            sshHost: "server",
            bindAddress: nil,
            additionalArguments: ["-p", "2222"]
        )
        defaults.set(
            try JSONEncoder().encode([legacy]),
            forKey: "savedTunnels.v1"
        )

        let store = TunnelStore(defaults: defaults)

        XCTAssertEqual(store.tunnels.count, 1)
        XCTAssertEqual(store.tunnels[0].id, legacy.id)
        XCTAssertEqual(store.tunnels[0].rules[0].kind, .local)
        let v2Data = try XCTUnwrap(defaults.data(forKey: "savedTunnels.v2"))
        XCTAssertEqual(
            try JSONDecoder().decode([Tunnel].self, from: v2Data),
            store.tunnels
        )
        XCTAssertNotNil(defaults.data(forKey: "savedTunnels.v1"))
    }

    func testGroupMutationsNormalizeMergeAndPersistWithoutASeparateGroupStore() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TunnelStore(defaults: defaults)
        var dashboard = makeLocalProfile()
        dashboard.name = "Dashboard"
        dashboard.groupTag = "Work"
        var desktop = makeLocalProfile()
        desktop.name = "Desktop"
        desktop.groupTag = "  work  "
        var photos = makeLocalProfile()
        photos.name = "Photos"
        photos.groupTag = "Personal"
        var scratch = makeLocalProfile()
        scratch.name = "Scratch"

        store.add(dashboard)
        store.add(desktop)
        store.add(photos)
        store.add(scratch)

        XCTAssertEqual(
            store.tunnels.map(\.groupTag),
            ["Work", "Work", "Personal", nil]
        )
        XCTAssertEqual(store.groupNames, ["Personal", "Work"])

        store.move(scratch, toGroup: " work ")
        XCTAssertEqual(store.tunnels[3].groupTag, "Work")
        store.move(scratch, toGroup: nil)
        XCTAssertNil(store.tunnels[3].groupTag)

        store.renameGroup("Work", to: " personal ")

        XCTAssertEqual(store.groupNames, ["Personal"])
        XCTAssertEqual(
            store.tunnels.map(\.groupTag),
            ["Personal", "Personal", "Personal", nil]
        )

        store.ungroup("PERSONAL")

        XCTAssertTrue(store.tunnels.allSatisfy { $0.groupTag == nil })
        XCTAssertFalse(store.grouping.isGrouped)
        XCTAssertNil(defaults.object(forKey: "savedTunnelGroups"))
        let persisted = try JSONDecoder().decode(
            [Tunnel].self,
            from: try XCTUnwrap(defaults.data(forKey: "savedTunnels.v2"))
        )
        XCTAssertTrue(persisted.allSatisfy { $0.groupTag == nil })

        var invalid = makeLocalProfile()
        invalid.groupTag = String(repeating: "x", count: 33)
        store.add(invalid)
        XCTAssertEqual(store.tunnels.count, 4)
    }

    /// Task 009. `grouping` is cached so the list body does not rebuild sections
    /// on every phase publish. Every mutation path must invalidate it.
    func testGroupingCacheInvalidatesOnEveryMutationPath() throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TunnelStore(defaults: defaults)

        XCTAssertFalse(store.grouping.isGrouped)

        var dashboard = makeLocalProfile()
        dashboard.name = "Dashboard"
        dashboard.groupTag = "Work"
        store.add(dashboard)
        XCTAssertEqual(store.grouping.groupNames, ["Work"])

        var renamedDashboard = store.tunnels[0]
        renamedDashboard.name = "Renamed"
        store.update(renamedDashboard)
        XCTAssertEqual(store.grouping.sections.first?.tunnels.first?.name, "Renamed")

        store.move(store.tunnels[0], toGroup: "Personal")
        XCTAssertEqual(store.grouping.groupNames, ["Personal"])

        store.renameGroup("Personal", to: "Home")
        XCTAssertEqual(store.grouping.groupNames, ["Home"])

        store.ungroup("Home")
        XCTAssertFalse(store.grouping.isGrouped)

        store.delete(store.tunnels[0])
        XCTAssertTrue(store.grouping.sections.allSatisfy { $0.tunnels.isEmpty })
    }

    func testMoveAndTagOnlyUpdatePreserveStartingRunningAndPendingBrowserWork() async throws {
        let fixture = try makeFakeSSHFixture()
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var openedURLs: [URL] = []
        let store = makeFakeStore(
            defaults: defaults,
            fixture: fixture,
            browserOpener: { openedURLs.append($0) }
        )
        let profile = makeLocalProfile()
        store.add(profile)

        store.openInBrowser(profile)
        XCTAssertEqual(store.phase(for: profile), .starting)
        store.move(profile, toGroup: "Work")
        XCTAssertEqual(store.phase(for: profile), .starting)

        let opened = await waitUntil { !openedURLs.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(store.phase(for: profile), .running)
        let invocationCount = parsedInvocations(
            try String(contentsOf: fixture.logURL)
        ).count

        store.renameGroup("Work", to: "Client")
        XCTAssertEqual(store.phase(for: profile), .running)
        XCTAssertEqual(store.tunnels[0].groupTag, "Client")

        var edited = store.tunnels[0]
        edited.groupTag = "Operations"
        store.update(edited)
        XCTAssertEqual(store.phase(for: profile), .running)
        XCTAssertEqual(store.tunnels[0].groupTag, "Operations")

        store.ungroup("Operations")
        XCTAssertEqual(store.phase(for: profile), .running)
        XCTAssertNil(store.tunnels[0].groupTag)
        XCTAssertEqual(
            parsedInvocations(try String(contentsOf: fixture.logURL)).count,
            invocationCount
        )
        XCTAssertEqual(openedURLs, [try XCTUnwrap(profile.unambiguousBrowserURL)])
        store.stop(profile)
    }

    func testGroupMovesPreserveStoppedFailedAndRetryingPhases() async throws {
        let (stoppedDefaults, stoppedSuite) = makeIsolatedDefaults()
        defer { stoppedDefaults.removePersistentDomain(forName: stoppedSuite) }
        let stoppedStore = TunnelStore(defaults: stoppedDefaults)
        let stopped = makeLocalProfile()
        stoppedStore.add(stopped)
        stoppedStore.move(stopped, toGroup: "Work")
        XCTAssertEqual(stoppedStore.phase(for: stopped), .stopped)

        let failed = Tunnel(
            name: "Invalid",
            localPort: 43_211,
            destinationHost: "localhost",
            destinationPort: 80,
            sshHost: "-blocked"
        )
        stoppedStore.add(failed)
        stoppedStore.start(failed)
        let failedPhase = stoppedStore.phase(for: failed)
        guard case .failed = failedPhase else {
            return XCTFail("Expected an invalid profile to fail.")
        }
        stoppedStore.move(failed, toGroup: "Work")
        XCTAssertEqual(stoppedStore.phase(for: failed), failedPhase)

        let (retryDefaults, retrySuite) = makeIsolatedDefaults()
        defer { retryDefaults.removePersistentDomain(forName: retrySuite) }
        let retryStore = TunnelStore(
            defaults: retryDefaults,
            sshExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
            retryDelayProvider: { _ in 1 }
        )
        let retrying = makeLocalProfile()
        retryStore.add(retrying)
        retryStore.start(retrying)
        let enteredRetry = await waitUntil {
            if case .retrying = retryStore.phase(for: retrying) { return true }
            return false
        }
        XCTAssertTrue(enteredRetry)
        let retryingPhase = retryStore.phase(for: retrying)
        retryStore.move(retrying, toGroup: "Operations")
        XCTAssertEqual(retryStore.phase(for: retrying), retryingPhase)
        retryStore.stop(retrying)
    }

    func testTagMutationKeepsAutomaticRuntimePortAndConnectionEditStillStops() async throws {
        let fixture = try makeFakeSSHFixture()
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeFakeStore(defaults: defaults, fixture: fixture)
        let rule = ForwardingRule(
            kind: .remote,
            listen: .tcp(bindAddress: "localhost", port: 0),
            destination: .tcp(host: "localhost", port: 3_000)
        )
        let profile = Tunnel(
            name: "Automatic",
            sshHost: "server",
            rules: [rule]
        )
        store.add(profile)
        store.start(profile)
        let reachedRunning = await waitUntil {
            store.phase(for: profile) == .running
        }
        XCTAssertTrue(reachedRunning)
        let allocatedPorts = store.runtimePorts(for: profile)

        store.move(profile, toGroup: "Work")

        XCTAssertEqual(store.phase(for: profile), .running)
        XCTAssertEqual(store.runtimePorts(for: profile), allocatedPorts)

        var connectionEdit = store.tunnels[0]
        connectionEdit.sshHost = "replacement-server"
        store.update(connectionEdit)

        XCTAssertEqual(store.phase(for: profile), .stopped)
        XCTAssertTrue(store.runtimePorts(for: profile).isEmpty)
    }

    func testInstallsMixedRulesSeparatelyAndMapsAutomaticPorts() async throws {
        let fixture = try makeFakeSSHFixture()
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeFakeStore(defaults: defaults, fixture: fixture)
        let firstAutomatic = ForwardingRule(
            kind: .remote,
            listen: .tcp(bindAddress: "localhost", port: 0),
            destination: .tcp(host: "localhost", port: 3000)
        )
        let secondAutomatic = ForwardingRule(
            kind: .remoteDynamic,
            listen: .tcp(bindAddress: "localhost", port: 0)
        )
        let profile = Tunnel(
            name: "Mixed",
            sshHost: "server",
            rules: [
                .localTCP(
                    bindAddress: "localhost",
                    port: 8080,
                    destinationHost: "web",
                    destinationPort: 80
                ),
                ForwardingRule(
                    kind: .localDynamic,
                    listen: .tcp(bindAddress: "localhost", port: 1080)
                ),
                firstAutomatic,
                secondAutomatic
            ],
            reverseSOCKSPolicy: .allow(["example.com:443"])
        )

        store.start(profile)
        defer { store.stop(profile) }
        let reachedRunning = await waitUntil {
            store.phase(for: profile) == .running
        }
        XCTAssertTrue(reachedRunning)

        XCTAssertEqual(
            store.runtimePorts(for: profile),
            [firstAutomatic.id: 47_000, secondAutomatic.id: 47_001]
        )

        let log = try String(contentsOf: fixture.logURL)
        let invocations = parsedInvocations(log)
        XCTAssertEqual(invocations.count, 5)
        XCTAssertTrue(invocations[0].contains("-M"))
        XCTAssertTrue(invocations[0].contains("ClearAllForwardings=yes"))
        XCTAssertTrue(
            invocations[0].contains(
                "PermitRemoteOpen=example.com:443"
            )
        )
        XCTAssertFalse(invocations[0].contains("-L"))
        XCTAssertTrue(invocations.contains { invocation in
            invocation.contains("-L")
                && invocation.contains("localhost:8080:web:80")
        })
        XCTAssertTrue(invocations.contains { invocation in
            invocation.contains("-D") && invocation.contains("localhost:1080")
        })
        XCTAssertTrue(invocations.contains { invocation in
            invocation.contains("-R")
                && invocation.contains("localhost:0:localhost:3000")
        })
        XCTAssertTrue(invocations.contains { invocation in
            invocation.contains("-R") && invocation.contains("localhost:0")
        })
        for helper in invocations.dropFirst() {
            XCTAssertTrue(helper.starts(with: ["-F", "none"]))
        }
    }

    func testRuleFailureRollsBackProfileAndStopsAfterConfiguredRetries() async throws {
        let fixture = try makeFakeSSHFixture(
            overrides: ["RELAYBAR_FAKE_SSH_FAIL_SPEC": "localhost:1080"]
        )
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeFakeStore(
            defaults: defaults,
            fixture: fixture,
            maxRetryAttempts: 0
        )
        let profile = Tunnel(
            name: "Failure",
            sshHost: "server",
            rules: [
                .localTCP(
                    bindAddress: "localhost",
                    port: 8080,
                    destinationHost: "web",
                    destinationPort: 80
                ),
                ForwardingRule(
                    kind: .localDynamic,
                    listen: .tcp(bindAddress: "localhost", port: 1080)
                )
            ]
        )

        store.start(profile)

        let reachedFailure = await waitUntil {
            if case .failed = store.phase(for: profile) { return true }
            return false
        }
        XCTAssertTrue(reachedFailure)
        guard case .failed(let message) = store.phase(for: profile) else {
            return XCTFail("Expected a failed profile.")
        }
        XCTAssertTrue(message.contains("fake forwarding failure"))
        XCTAssertTrue(store.runtimePorts(for: profile).isEmpty)
        XCTAssertEqual(store.runningCount, 0)
    }

    func testHungControlOperationTimesOutAndRollsBackProfile() async throws {
        let fixture = try makeFakeSSHFixture(
            overrides: ["RELAYBAR_FAKE_SSH_DELAY_SPEC": "localhost:1080"]
        )
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeFakeStore(
            defaults: defaults,
            fixture: fixture,
            maxRetryAttempts: 0,
            controlOperationTimeout: 0.1
        )
        let profile = Tunnel(
            name: "Hung helper",
            sshHost: "server",
            rules: [
                ForwardingRule(
                    kind: .localDynamic,
                    listen: .tcp(bindAddress: "localhost", port: 1080)
                )
            ]
        )

        store.start(profile)

        let reachedFailure = await waitUntil {
            if case .failed = store.phase(for: profile) { return true }
            return false
        }
        XCTAssertTrue(reachedFailure)
        guard case .failed(let message) = store.phase(for: profile) else {
            return XCTFail("Expected a failed profile.")
        }
        XCTAssertTrue(message.contains("timed out"))
        XCTAssertEqual(store.runningCount, 0)
    }

    func testAutomaticPortsClearOnStopAndChangeAfterRestart() async throws {
        let fixture = try makeFakeSSHFixture()
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeFakeStore(defaults: defaults, fixture: fixture)
        let rule = ForwardingRule(
            kind: .remote,
            listen: .tcp(bindAddress: "localhost", port: 0),
            destination: .tcp(host: "localhost", port: 3000)
        )
        let profile = Tunnel(name: "Automatic", sshHost: "server", rules: [rule])

        store.start(profile)
        let firstStartRunning = await waitUntil {
            store.phase(for: profile) == .running
        }
        XCTAssertTrue(firstStartRunning)
        XCTAssertEqual(store.runtimePorts(for: profile)[rule.id], 47_000)

        store.stop(profile)
        XCTAssertTrue(store.runtimePorts(for: profile).isEmpty)
        XCTAssertEqual(store.phase(for: profile), .stopped)

        store.start(profile)
        defer { store.stop(profile) }
        let secondStartRunning = await waitUntil {
            store.phase(for: profile) == .running
        }
        XCTAssertTrue(secondStartRunning)
        XCTAssertEqual(store.runtimePorts(for: profile)[rule.id], 47_001)
    }

    /// Task 007. The stopped launch's control operation outlives `stop`, because
    /// the fixture ignores SIGTERM. Control state is scoped to the launch that
    /// owns it, so the replacement launch must not see a conflict.
    func testRestartIsNotBlockedByAStoppedLaunchesControlOperation() async throws {
        let rule = ForwardingRule(
            kind: .local,
            listen: .tcp(bindAddress: "localhost", port: 4_501),
            destination: .tcp(host: "localhost", port: 3_000)
        )
        let fixture = try makeFakeSSHFixture(
            overrides: ["RELAYBAR_FAKE_SSH_IGNORE_TERM_SPEC": rule.specification]
        )
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeFakeStore(defaults: defaults, fixture: fixture)
        let profile = Tunnel(name: "Restart", sshHost: "server", rules: [rule])

        store.start(profile)
        let controlOperationStarted = await waitUntil {
            let log = (try? String(contentsOf: fixture.logURL, encoding: .utf8)) ?? ""
            return log.contains("ARG:forward")
        }
        XCTAssertTrue(controlOperationStarted)

        // Still in flight: stop and restart before it can be reaped.
        store.stop(profile)
        XCTAssertEqual(store.phase(for: profile), .stopped)
        store.start(profile)
        defer { store.stop(profile) }

        let restarted = await waitUntil(timeoutIterations: 800) {
            store.phase(for: profile) == .running
        }
        if case .failed(let message) = store.phase(for: profile) {
            XCTFail("Restart failed: \(message)")
        }
        XCTAssertTrue(restarted)
    }

    func testRefusesToReplaceExistingLocalSocketPath() throws {
        let fixture = try makeFakeSSHFixture()
        defer { fixture.cleanup() }
        let socketPath = "/tmp/RelayBarTest-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        try Data("not a socket".utf8).write(
            to: URL(fileURLWithPath: socketPath)
        )
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeFakeStore(defaults: defaults, fixture: fixture)
        let profile = Tunnel(
            name: "Socket",
            sshHost: "server",
            rules: [
                ForwardingRule(
                    kind: .local,
                    listen: .unix(path: socketPath),
                    destination: .tcp(host: "localhost", port: 3000)
                )
            ],
            streamLocalSettings: StreamLocalSettings(
                bindMask: 0o077,
                unlinkStaleSocket: true
            )
        )

        store.start(profile)

        guard case .failed(let message) = store.phase(for: profile) else {
            return XCTFail("Expected preflight failure.")
        }
        XCTAssertTrue(message.contains("will not replace"))
        XCTAssertEqual(
            try String(contentsOfFile: socketPath),
            "not a socket"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.logURL.path))
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
        let tunnel = makeLocalProfile()
        store.add(tunnel)

        store.start(tunnel)

        let retriesExhausted = await waitUntil {
            if case .failed = store.phase(for: tunnel) { return true }
            return false
        }
        XCTAssertTrue(retriesExhausted)
        guard case .failed(let message) = store.phase(for: tunnel) else {
            return XCTFail("Expected retries to exhaust.")
        }
        XCTAssertTrue(message.contains("Automatic retry stopped after 2 attempts."))
        XCTAssertEqual(store.runningCount, 0)
    }

    func testManualStopCancelsPendingRetry() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TunnelStore(
            defaults: defaults,
            sshExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
            retryDelayProvider: { _ in 0.2 }
        )
        let tunnel = makeLocalProfile()
        store.start(tunnel)

        let enteredRetry = await waitUntil {
            if case .retrying = store.phase(for: tunnel) { return true }
            return false
        }
        XCTAssertTrue(enteredRetry)

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

    func testBrowserOpenWaitsUntilAllRulesAreInstalled() async throws {
        let fixture = try makeFakeSSHFixture()
        defer { fixture.cleanup() }
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var openedURLs: [URL] = []
        let store = makeFakeStore(
            defaults: defaults,
            fixture: fixture,
            browserOpener: { openedURLs.append($0) }
        )
        let tunnel = makeLocalProfile()

        store.openInBrowser(tunnel)

        let opened = await waitUntil { !openedURLs.isEmpty }
        XCTAssertTrue(opened)
        XCTAssertEqual(openedURLs, [try XCTUnwrap(tunnel.unambiguousBrowserURL)])
        XCTAssertEqual(store.phase(for: tunnel), .running)
        store.stop(tunnel)
    }

    private func makeLocalProfile() -> Tunnel {
        Tunnel(
            name: "Web",
            localPort: 43_210,
            destinationHost: "127.0.0.1",
            destinationPort: 80,
            sshHost: "example.com"
        )
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "RelayBarTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeFakeStore(
        defaults: UserDefaults,
        fixture: FakeSSHFixture,
        maxRetryAttempts: Int = 1,
        browserOpener: @escaping (URL) -> Void = { _ in },
        controlOperationTimeout: TimeInterval = 10
    ) -> TunnelStore {
        TunnelStore(
            defaults: defaults,
            sshExecutableURL: fakeSSHURL,
            maxRetryAttempts: maxRetryAttempts,
            retryDelayProvider: { _ in 0.01 },
            browserOpener: browserOpener,
            processEnvironment: fixture.environment,
            controlOperationTimeout: controlOperationTimeout
        )
    }

    private var fakeSSHURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh.sh")
    }

    private func makeFakeSSHFixture(
        overrides: [String: String] = [:]
    ) throws -> FakeSSHFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayBarSSHTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let logURL = directory.appendingPathComponent("ssh.log")
        let counterURL = directory.appendingPathComponent("counter")
        try Data("47000\n".utf8).write(to: counterURL)
        var environment = [
            "RELAYBAR_FAKE_SSH_LOG": logURL.path,
            "RELAYBAR_FAKE_SSH_COUNTER": counterURL.path
        ]
        environment.merge(overrides) { _, replacement in replacement }
        return FakeSSHFixture(
            directory: directory,
            logURL: logURL,
            environment: environment
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 400,
        condition: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func parsedInvocations(_ log: String) -> [[String]] {
        var invocations: [[String]] = []
        var current: [String]?
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "BEGIN" {
                current = []
            } else if line == "END" {
                if let current { invocations.append(current) }
                current = nil
            } else if line.hasPrefix("ARG:"), current != nil {
                current?.append(String(line.dropFirst(4)))
            }
        }
        return invocations
    }
}

private struct FakeSSHFixture {
    let directory: URL
    let logURL: URL
    let environment: [String: String]

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
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
