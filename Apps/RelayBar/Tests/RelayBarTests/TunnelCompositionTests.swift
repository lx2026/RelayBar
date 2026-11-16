import Composition
import Foundation
import XCTest
@testable import RelayBar

/// The tunnel store is the single owner of each profile's processes. These tests run it inside the
/// composed app against the fake SSH fixture.
@MainActor
final class TunnelCompositionTests: XCTestCase {
    func testRetryPreferencePreservesLiveProcessAndStore() async throws {
        let a = profile("Running", port: 43_290)
        let fixture = try Fixture(profiles: [a])
        addTeardownBlock { await fixture.close() }
        await fixture.app.start()
        let store = try XCTUnwrap(fixture.app.store)
        XCTAssertEqual(store.maxRetryAttempts, 2, "The imported preference is applied when the store loads")
        store.start(a)
        let running = await waitUntil { store.phase(for: a) == .running }
        XCTAssertTrue(running)
        let generation = try XCTUnwrap(fixture.app.runtime.status("tunnels")?.generation)
        try await fixture.app.setRetryLimit(0)
        XCTAssertTrue(fixture.app.store === store)
        XCTAssertEqual(store.phase(for: a), .running)
        XCTAssertEqual(store.maxRetryAttempts, 0)
        XCTAssertEqual(fixture.app.runtime.status("tunnels")?.generation, generation)
        XCTAssertEqual(try fixture.masterCount(), 1)
        XCTAssertEqual(store.terminatingSSHProcessCount, 0)
    }

    func testFailedPreferenceSaveCannotCancelPendingRetryAndCommittedZeroDoes() async throws {
        let a = profile("Retrying", port: 43_291)
        let fixture = try Fixture(profiles: [a], overrides: ["RELAYBAR_FAKE_SSH_FAIL_MASTER": "1"])
        addTeardownBlock { await fixture.close() }
        await fixture.app.start()
        let store = try XCTUnwrap(fixture.app.store)
        store.start(a)
        let retrying = await waitUntil {
            if case .retrying(let attempt, _, _, _) = store.phase(for: a) { return attempt == 1 }
            return false
        }
        XCTAssertTrue(retrying)
        let first = store.phase(for: a)
        let backup = fixture.preferencesURL.appendingPathExtension("previous")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        do { try await fixture.app.setRetryLimit(0); XCTFail("Save should fail") } catch {}
        XCTAssertEqual(store.phase(for: a), first)
        XCTAssertEqual(store.maxRetryAttempts, 2)
        try FileManager.default.removeItem(at: backup)
        try await fixture.app.setRetryLimit(5)
        let next = await waitUntil {
            if case .retrying(let attempt, let limit, _, _) = store.phase(for: a) { return attempt == 2 && limit == 5 }
            return false
        }
        XCTAssertTrue(next)
        try await fixture.app.setRetryLimit(0)
        guard case .failed = store.phase(for: a) else { return XCTFail("Committed zero must stop retries") }
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(try fixture.masterCount(), 2)
        XCTAssertEqual(fixture.defaults.integer(forKey: "sshRetryLimit.v1"), 2)
    }

    func testGroupCommandsUseSnapshotMembersAndRestartOnlyActiveMembers() async throws {
        let a = profile("A", port: 43_286), b = profile("B", port: 43_287)
        var outside = profile("Outside", port: 43_288)
        outside.groupTag = "Personal"
        var unsafe = profile("Unsafe", port: 43_289)
        unsafe.sshHost = "-invalid"
        let fixture = try Fixture(profiles: [a, b, outside, unsafe])
        addTeardownBlock { await fixture.close() }
        await fixture.app.start()
        let store = try XCTUnwrap(fixture.app.store)
        store.start(a); store.start(outside)
        let initiallyRunning = await waitUntil { store.phase(for: a) == .running && store.phase(for: outside) == .running }
        XCTAssertTrue(initiallyRunning)

        store.startGroup("Work")
        store.move(b, toGroup: "Personal")
        store.renameGroup("Work", to: "Client")
        let startedFromSnapshot = await waitUntil { store.phase(for: b) == .running }
        XCTAssertTrue(startedFromSnapshot)
        XCTAssertEqual(try fixture.masterCount(), 3, "The already running member is not relaunched")
        let failure = store.phase(for: unsafe)
        guard case .failed = failure else { return XCTFail("Unsafe member did not fail independently") }

        store.restartGroup("Client")
        let restarted = await waitUntil { store.phase(for: a) == .running && (try? fixture.masterCount()) == 4 }
        XCTAssertTrue(restarted)
        XCTAssertEqual(store.phase(for: unsafe), failure)
        store.stopGroup("Client")
        XCTAssertEqual(store.phase(for: a), .stopped)
        XCTAssertEqual(store.phase(for: unsafe), failure)
        XCTAssertEqual(store.phase(for: b), .running)
        XCTAssertEqual(store.phase(for: outside), .running)
        XCTAssertEqual(try fixture.masterCount(), 4)
        await fixture.close()
    }

    func testGroupEditsPreserveRunningProfilesAndIndividualStopLeavesPeerRunning() async throws {
        let a = profile("A", port: 43_280), b = profile("B", port: 43_281)
        let fixture = try Fixture(profiles: [a, b])
        addTeardownBlock { await fixture.close() }
        await fixture.app.start()
        XCTAssertNil(fixture.app.errorMessage)
        let store = try XCTUnwrap(fixture.app.store)
        XCTAssertEqual(fixture.app.runtime.statuses.map(\.id),
                       ["tunnels", "tunnels.retry-limit", "recovery", "updates", "updates.schedule", "login"],
                       "Profiles and groups are data in the store, not features")
        let parent = try XCTUnwrap(fixture.app.runtime.status("tunnels")?.generation)
        let savedPreferences = try Data(contentsOf: fixture.preferencesURL)
        store.startGroup("Work")
        let running = await waitUntil { store.phase(for: a) == .running && store.phase(for: b) == .running }
        XCTAssertTrue(running)

        store.move(a, toGroup: "Personal")
        store.renameGroup("Personal", to: "Home")
        store.renameGroup("Work", to: "Client")
        XCTAssertEqual(store.phase(for: a), .running)
        XCTAssertEqual(store.phase(for: b), .running)
        XCTAssertEqual(try fixture.masterCount(), 2, "Group edits never relaunch a profile")
        XCTAssertEqual(fixture.app.runtime.status("tunnels")?.generation, parent)
        XCTAssertEqual(try Data(contentsOf: fixture.preferencesURL), savedPreferences)

        store.stop(a)
        XCTAssertEqual(store.phase(for: a), .stopped)
        XCTAssertEqual(store.phase(for: b), .running)
        store.start(a)
        let resumed = await waitUntil { store.phase(for: a) == .running }
        XCTAssertTrue(resumed)
        XCTAssertEqual(store.phase(for: b), .running)
        XCTAssertEqual(try fixture.masterCount(), 3)
        await fixture.close()
        XCTAssertEqual(store.terminatingSSHProcessCount, 0)
        XCTAssertTrue(fixture.app.runtime.statuses.isEmpty)
    }

    func testEditAndDeleteReaddReplaceOnlyTheAffectedProfile() async throws {
        let a = profile("A", port: 43_282), b = profile("B", port: 43_283)
        let fixture = try Fixture(profiles: [a, b])
        addTeardownBlock { await fixture.close() }
        await fixture.app.start()
        let store = try XCTUnwrap(fixture.app.store)
        store.startGroup("Work")
        let running = await waitUntil { store.phase(for: a) == .running && store.phase(for: b) == .running }
        XCTAssertTrue(running)
        var edited = a
        edited.sshHost = "replacement.invalid"
        store.update(edited)
        store.start(edited)
        let editedRunning = await waitUntil { store.phase(for: edited) == .running }
        XCTAssertTrue(editedRunning)
        store.delete(edited); store.add(edited); store.start(edited)
        let replacedRunning = await waitUntil { store.phase(for: edited) == .running && store.terminatingSSHProcessCount == 0 }
        XCTAssertTrue(replacedRunning)
        XCTAssertEqual(store.phase(for: b), .running)
        XCTAssertEqual(try fixture.masterCount(), 4)
        await fixture.close()
    }

    func testGroupEditsPreserveRetryBudgetAndExistingDeadline() async throws {
        let a = profile("Retrying", port: 43_284)
        let fixture = try Fixture(profiles: [a], overrides: ["RELAYBAR_FAKE_SSH_FAIL_MASTER": "1"])
        addTeardownBlock { await fixture.close() }
        await fixture.app.start()
        let store = try XCTUnwrap(fixture.app.store)
        store.start(a)
        let retrying = await waitUntil {
            if case .retrying(let attempt, _, _, _) = store.phase(for: a) { return attempt == 1 }
            return false
        }
        XCTAssertTrue(retrying)
        let first = store.phase(for: a)
        store.renameGroup("Work", to: "Client")
        store.move(a, toGroup: "Operations")
        XCTAssertEqual(store.phase(for: a), first)
        let next = await waitUntil {
            if case .retrying(let attempt, _, _, _) = store.phase(for: a) { return attempt == 2 }
            return false
        }
        XCTAssertTrue(next)
        XCTAssertEqual(try fixture.masterCount(), 2)
        await fixture.close()
    }

    func testBrowserOpensThroughTheInjectedOpenerAndAStoppedAppRejectsCommands() async throws {
        let a = profile("Browser", port: 43_285)
        let fixture = try Fixture(profiles: [a])
        addTeardownBlock { await fixture.close() }
        await fixture.app.start()
        let store = try XCTUnwrap(fixture.app.store)
        store.openInBrowser(a)
        let opened = await waitUntil { fixture.opened.urls.count == 1 }
        XCTAssertTrue(opened)
        XCTAssertEqual(store.phase(for: a), .running)
        XCTAssertEqual(try fixture.masterCount(), 1)

        await fixture.app.stop()
        XCTAssertNil(fixture.app.store)
        XCTAssertEqual(store.terminatingSSHProcessCount, 0, "Shutdown waits for every child to be reaped")
        let saved = fixture.defaults.data(forKey: "savedTunnels.v2")
        store.start(a); store.openInBrowser(a); store.delete(a)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.defaults.data(forKey: "savedTunnels.v2"), saved)
        XCTAssertEqual(try fixture.masterCount(), 1, "A retained store cannot launch SSH after its feature unloaded")
        XCTAssertEqual(fixture.opened.urls.count, 1)
        await fixture.close()
    }

    func testStartingATunnelDoesNotWaitForAClosingWindow() async throws {
        let a = profile("Independent", port: 43_292)
        let files = SlowShutdownFileService()
        let fixture = try Fixture(profiles: [a], fileService: files)
        addTeardownBlock { files.release(); await fixture.close() }
        await fixture.app.start()
        let store = try XCTUnwrap(fixture.app.store)
        try await fixture.app.setRemoteFilesOpen(true)
        XCTAssertNotNil(fixture.app.windows)

        // The window's SSH session is slow to go away, as when the network has hung.
        fixture.app.closeRemoteFiles()
        let closing = await waitUntil { fixture.app.runtime.status("remote.files")?.phase == .unloading }
        XCTAssertTrue(closing)
        store.start(a)
        let running = await waitUntil { store.phase(for: a) == .running }
        XCTAssertTrue(running)
        XCTAssertEqual(fixture.app.runtime.status("remote.files")?.phase, .unloading,
                       "The tunnel started while the window was still unloading")
        files.release()
        await fixture.app.runtime.settled()
        XCTAssertNil(fixture.app.runtime.status("remote.files"))
        await fixture.close()
    }

    private func profile(_ name: String, port: Int) -> Tunnel {
        Tunnel(name: name, localPort: port, destinationHost: "127.0.0.1", destinationPort: 80,
            sshHost: "fixture.invalid", groupTag: "Work")
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class Fixture {
    let app: RelayBarComposition
    let defaults: UserDefaults
    let directory: URL
    let preferencesURL: URL
    let logURL: URL
    let suite: String
    let opened = OpenedURLs()

    init(profiles: [Tunnel], overrides: [String: String] = [:], fileService: (any RemoteFileServing)? = nil) throws {
        let suite = "TunnelComposition.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        self.suite = suite; self.defaults = defaults
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let log = directory.appendingPathComponent("ssh.log")
        logURL = log
        let preferencesURL = directory.appendingPathComponent("preferences.json")
        self.preferencesURL = preferencesURL
        defaults.set(try JSONEncoder().encode(profiles), forKey: "savedTunnels.v2")
        defaults.set(2, forKey: "sshRetryLimit.v1")
        var environment = ["RELAYBAR_FAKE_SSH_LOG": log.path, "RELAYBAR_FAKE_SSH_IGNORE_MASTER_TERM": "1"]
        environment.merge(overrides) { _, new in new }
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh.sh")
        let opened = self.opened
        app = RelayBarComposition(defaults: defaults, preferencesURL: preferencesURL,
            startsBridge: false, showsWindows: false,
            makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
            makeTunnels: { TunnelStore(defaults: defaults, sshExecutableURL: executable, maxRetryAttempts: 2,
                retryDelayProvider: { _ in 1 }, browserOpener: { opened.urls.append($0) }, processEnvironment: environment,
                processTerminationGracePeriod: 0.1, persistsRetryLimit: false) },
            makeFileService: { fileService ?? SFTPRemoteFileService() },
            makeUpdates: { _ in UnavailableUpdateService() }, loginService: TunnelLoginService())
    }

    func masterCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return 0 }
        return try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").filter { $0 == "ARG:-M" }.count
    }

    func close() async {
        await app.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class OpenedURLs { var urls: [URL] = [] }

private struct TunnelLoginService: LoginItemServicing {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openLoginItemsSettings() {}
}

/// A file service whose teardown stays open until released, standing in for a hung SSH session.
private final class SlowShutdownFileService: RemoteFileServing, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] { [] }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {}
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL { throw CancellationError() }
    func shutdownAndWait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
        }
    }
    func release() {
        lock.lock(); released = true
        let pending = waiters; waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}
