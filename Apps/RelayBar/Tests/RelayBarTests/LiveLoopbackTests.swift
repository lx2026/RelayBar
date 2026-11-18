// Exercises the real /usr/bin/ssh and /usr/bin/sftp paths against a throwaway
// loopback sshd. Skipped unless RELAYBAR_LOOPBACK_SSH_DIR points at that setup.
import Foundation
import BridgeProtocol
import Composition
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
            "-o", "StrictHostKeyChecking=yes"
        ]
    }

    private func executable(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: try fixtureDirectory).appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "Use fixture wrappers with isolated SSH config and known hosts")
        return url
    }

    private func server() throws -> RemoteServer {
        RemoteServer(id: UUID(), name: "Loopback", sshHost: "127.0.0.1", additionalArguments: try makeArguments())
    }

    private func workFolder() throws -> URL {
        let root = URL(fileURLWithPath: try fixtureDirectory).appendingPathComponent("work-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func windowConsumer(_ service: SFTPRemoteFileService) async throws -> (RelayBarComposition, LiveWindow) {
        let suite = "RelayLiveWindow.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let window = LiveWindow()
        let app = RelayBarComposition(defaults: defaults, startsBridge: false, showsWindows: false,
            makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
            makeFileService: { service }, makeUpdates: { _ in UnavailableUpdateService() }, loginService: LoopbackLoginService(),
            additionalFeatures: [FeatureNode("live.consumer") { LiveConsumer(window: window) }])
        addTeardownBlock { await app.stop(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await app.start()
        try await app.setRemoteFilesOpen(true)
        XCTAssertNotNil(window.feature, "The consumer loads once the window offers its reader")
        return (app, window)
    }

    func testLiveHelperArchiveRestoreAndBatchDeletePreserveUnselectedFiles() async throws {
        let root = try workFolder(), server = try server()
        let originals = ["a.jpg": Data("image bytes".utf8), "a.prompt.json": Data("{\"prompt\":\"fixture\"}".utf8),
            "a.txt": Data("companion".utf8), "keep.md": Data("# Keep this document".utf8)]
        for (name, bytes) in originals { try bytes.write(to: root.appendingPathComponent(name)) }
        let service = SFTPRemoteFileService(executableURL: try executable("sftp-fixture"),
            sshExecutableURL: try executable("ssh-fixture"), sessionTemporaryDirectory: URL(fileURLWithPath: try fixtureDirectory))
        let (app, context) = try await windowConsumer(service)
        func call(_ input: BridgeAssetInput) async throws -> BridgeAssetResult {
            try await context.effects.run { try await context.reader.frameAsset(server: server, input: input) }
        }
        let listing = try await call(.init(action: "list", root: root.path))
        let entries = try XCTUnwrap(listing.entries), primary = try XCTUnwrap(entries.first { $0.name == "a.jpg" })
        var archive = BridgeAssetInput(action: "archive", root: root.path)
        archive.members = [primary] + FrameBridgeBroker.companions(for: primary, entries: entries)
        XCTAssertEqual(Set(archive.members.map(\.name)), ["a.jpg", "a.prompt.json", "a.txt"])
        let archived = try await call(archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.jpg").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("keep.md")), originals["keep.md"])
        var restore = BridgeAssetInput(action: "restore", root: root.path)
        restore.recordID = try XCTUnwrap(archived.recordID)
        _ = try await call(restore)
        for (name, bytes) in originals { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes) }
        let restoredListing = try await call(.init(action: "list", root: root.path))
        let current = try XCTUnwrap(restoredListing.entries), restored = try XCTUnwrap(current.first { $0.name == "a.jpg" })
        var target = BridgeAssetInput(action: "delete", root: root.path)
        target.members = [restored] + FrameBridgeBroker.companions(for: restored, entries: current)
        var batch = BridgeAssetInput(action: "deleteBatch", root: root.path); batch.batch = [target]
        let deleted = try await call(batch)
        XCTAssertEqual(deleted.outcomes?.count, 1)
        XCTAssertNil(deleted.outcomes?.first?.error)
        for member in target.members { XCTAssertFalse(FileManager.default.fileExists(atPath: member.path)) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("keep.md")), originals["keep.md"])
        let collection = try await call(.init(action: "collection", root: root.path))
        XCTAssertTrue(collection.records?.isEmpty == true)
        await app.stop()
        XCTAssertTrue(app.runtime.statuses.isEmpty)
    }

    func testLiveUploadWindowWithdrawalCleansStagingAndReapsMaster() async throws {
        let local = try workFolder(), remote = try workFolder(), server = try server()
        let file = local.appendingPathComponent("upload.bin")
        try Data(repeating: 0x58, count: 4 * 1_024 * 1_024).write(to: file)
        let service = SFTPRemoteFileService(executableURL: try executable("sftp-slow-fixture"),
            sshExecutableURL: try executable("ssh-fixture"), sessionTemporaryDirectory: URL(fileURLWithPath: try fixtureDirectory))
        let (app, context) = try await windowConsumer(service)
        let complete = local.appendingPathComponent("completed.txt")
        try Data("first upload".utf8).write(to: complete)
        try await context.effects.run {
            try await context.reader.upload(server: server, localFile: complete,
                remoteDirectory: remote.path, replaceExisting: false) { _ in }
        }
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent(complete.lastPathComponent)), Data("first upload".utf8))
        let replacement = Data("approved replacement".utf8)
        try replacement.write(to: complete)
        try await context.effects.run {
            try await context.reader.upload(server: server, localFile: complete,
                remoteDirectory: remote.path, replaceExisting: true) { _ in }
        }
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent(complete.lastPathComponent)), replacement)
        let operation = Task {
            try await context.effects.run {
                try await context.reader.upload(server: server, localFile: file,
                    remoteDirectory: remote.path, replaceExisting: false) { _ in }
            }
        }
        let staged = await waitUntil {
            (try? FileManager.default.contentsOfDirectory(at: remote, includingPropertiesForKeys: [.fileSizeKey]))?.contains {
                $0.lastPathComponent.hasPrefix(".relaybar-upload-") && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            } == true
        }
        XCTAssertTrue(staged, "The real server must receive upload bytes before withdrawal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent(file.lastPathComponent).path))
        try await app.setRemoteFilesOpen(false)
        do { try await operation.value; XCTFail("Interrupted upload reported success") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.path), [complete.lastPathComponent], "Cancelled staging must be removed on the live server")
        XCTAssertEqual(try Data(contentsOf: remote.appendingPathComponent(complete.lastPathComponent)), replacement)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory)
            .filter { $0.hasPrefix(RemoteFileSSHSession.privateDirectoryPrefix) }
        XCTAssertTrue(remaining.isEmpty, "The retired SSH master must release its private control directory")
        XCTAssertFalse(context.isActive)
        await app.stop()
    }

    func testLiveCommittedArchiveLosesReceiptOnWithdrawalAndIsNotReplayed() async throws {
        let root = try workFolder(), server = try server(), fixture = URL(fileURLWithPath: try fixtureDirectory)
        let image = root.appendingPathComponent("a.jpg"), bytes = Data("remote committed bytes".utf8)
        try bytes.write(to: image)
        let control = fixture.appendingPathComponent("receipt-control.json")
        let marker = fixture.appendingPathComponent("receipt-ready"), calls = fixture.appendingPathComponent("receipt-calls")
        let data = try JSONSerialization.data(withJSONObject: ["root": root.path, "action": "archive"])
        try data.write(to: control)
        addTeardownBlock {
            for file in [control, marker, calls] { try? FileManager.default.removeItem(at: file) }
        }
        func service() throws -> SFTPRemoteFileService {
            SFTPRemoteFileService(executableURL: try executable("sftp-fixture"),
                sshExecutableURL: try executable("ssh-receipt-fixture"), sessionTemporaryDirectory: fixture)
        }
        let (app, context) = try await windowConsumer(service())
        let listing = try await context.effects.run {
            try await context.reader.frameAsset(server: server, input: .init(action: "list", root: root.path))
        }
        var archive = BridgeAssetInput(action: "archive", root: root.path)
        archive.members = [try XCTUnwrap(listing.entries?.first { $0.name == "a.jpg" })]
        let input = archive
        let operation = Task {
            try await context.effects.run {
                try await context.reader.frameAsset(server: server, input: input)
            }
        }
        let committed = await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(committed, "The wrapper holds only a receipt returned by the real SSH server")
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        try await app.setRemoteFilesOpen(false)
        do { _ = try await operation.value; XCTFail("Withdrawn mutation returned its held acknowledgement") } catch {}
        try FileManager.default.removeItem(at: control)
        await app.stop()
        let (reopened, fresh) = try await windowConsumer(service())
        let collection = try await fresh.effects.run {
            try await fresh.reader.frameAsset(server: server, input: .init(action: "collection", root: root.path))
        }
        let record = try XCTUnwrap(collection.records?.first)
        XCTAssertEqual(collection.records?.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(record.members.first?.path))), bytes)
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "archive\n", "Reconnect must not repeat a submitted mutation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path), "Transport retirement does not undo the server's archive")
        await reopened.stop()
    }

    /// Real control socket, real `-O forward`, real data through the forward,
    /// and a real allocated remote port. Then stop and immediately restart,
    /// which is the Task 007 path against genuine OpenSSH timing.
    func testInstallsRulesCarriesTrafficAndRestartsAgainstRealSSH() async throws {
        let arguments = try makeArguments()
        let suiteName = "RelayBarLoopback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = TunnelStore(
            defaults: defaults,
            sshExecutableURL: try executable("ssh-fixture"),
            maxRetryAttempts: 2,
            retryDelayProvider: { _ in 0.2 }
        )
        let app = RelayBarComposition(defaults: defaults, startsBridge: false, showsWindows: false,
            makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
            makeTunnels: { store }, makeUpdates: { _ in UnavailableUpdateService() }, loginService: LoopbackLoginService())
        addTeardownBlock { await app.stop(); UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        await app.start()
        XCTAssertNil(app.errorMessage)
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
        await app.stop()
        XCTAssertEqual(store.terminatingSSHProcessCount, 0)
        XCTAssertTrue(app.runtime.statuses.isEmpty)
    }

    /// Against a real server: entries whose names hold glob metacharacters list
    /// correctly and can be opened, because sftp's quoting matches them
    /// literally. This is the evidence that reverted the Task 005 refusal.
    func testListsAndOpensRealGlobNamedEntries() async throws {
        let directory = try fixtureDirectory
        let service = SFTPRemoteFileService(executableURL: try executable("sftp-fixture"), sshExecutableURL: try executable("ssh-fixture"))
        addTeardownBlock { await service.shutdownAndWait() }
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

/// A feature outside the window that needs the window's reader, as Frame's host does.
@MainActor
private final class LiveWindow {
    var feature: FeatureContext!
    var reader: (any RemoteFileServing)!
    var effects: EffectScope { feature.effects }
    var isActive: Bool { feature.isActive }
}

private struct LiveConsumer: Feature {
    @Constant var window: LiveWindow
    @Need(RelayServices.PreviewReader.self) var reader
    func run(_ context: FeatureContext) async throws { window.feature = context; window.reader = reader }
}

private struct LoopbackLoginService: LoginItemServicing {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openLoginItemsSettings() {}
}
