import BridgeProtocol
import Foundation
import XCTest
@testable import RelayBar

@MainActor final class FrameBridgeTests: XCTestCase {
    private func fixture() throws -> (FrameBridgeBroker, RemoteServerCatalog, UserDefaults, BridgeServiceFixture) {
        let name = "FrameBridgeTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let catalog = RemoteServerCatalog(defaults: defaults)
        _ = try catalog.add(name: "Fixture", sshHost: "fixture.invalid")
        let service = BridgeServiceFixture()
        let broker = FrameBridgeBroker(catalog: catalog, defaults: defaults, tunnels: { [] }, makeService: { service })
        return (broker, catalog, defaults, service)
    }
    func testConsentVersionAndUnsupportedMutation() throws {
        let (broker, _, defaults, _) = try fixture()
        XCTAssertNotNil(broker.handle(BridgeRequest("catalog")).error)
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        XCTAssertEqual(broker.handle(BridgeRequest("catalog")).sources?.count, 1)
        for operation in ["delete", "upload", "archive", "shell"] { XCTAssertNotNil(broker.handle(BridgeRequest(operation)).error) }
        var request = BridgeRequest("catalog"); request.version = 1
        XCTAssertNotNil(broker.handle(request).error)
        broker.revoke()
        XCTAssertFalse(broker.isAllowed)
        XCTAssertNotNil(broker.handle(BridgeRequest("catalog")).error)
    }
    private func list(_ broker: FrameBridgeBroker, source: BridgeSource, path: String) async throws -> BridgeResponse {
        var request = BridgeRequest("list"); request.sourceID = source.id; request.path = path
        var result = broker.handle(request)
        let job = try XCTUnwrap(result.jobID)
        var status = BridgeRequest("status"); status.jobID = job
        for _ in 0..<100 where result.status == "pending" {
            try await Task.sleep(for: .milliseconds(1))
            result = broker.handle(status)
        }
        XCTAssertEqual(result.status, "ready")
        var release = BridgeRequest("release"); release.jobID = job
        _ = broker.handle(release)
        XCTAssertNotNil(broker.handle(status).error)
        return result
    }
    func testFrameListingsAndExplicitOpensNeverChangeRelayBarHistory() async throws {
        let (broker, catalog, defaults, _) = try fixture()
        defer { broker.stop() }
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        let notifications = HistoryNotificationCount()
        let observer = NotificationCenter.default.addObserver(forName: .frameRemoteHistoryChanged, object: nil, queue: nil) { _ in
            notifications.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let result = try await list(broker, source: source, path: "/photos")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.entries?.map(\.name), ["a.jpg"])
        XCTAssertTrue(catalog.recentLocations(from: []).isEmpty)
        XCTAssertEqual(notifications.value, 0)
        var remember = BridgeRequest("rememberOpen"); remember.sourceID = source.id; remember.path = "/photos"
        XCTAssertNil(broker.handle(remember).error)
        XCTAssertTrue(catalog.recentLocations(from: []).isEmpty)
        catalog.recordSuccessfulOpen(try XCTUnwrap(catalog.servers(from: []).first), path: "/photos")
        let originalID = try XCTUnwrap(catalog.recentLocations(from: []).first?.id)
        XCTAssertEqual(catalog.recentLocations(from: []).map(\.path), ["/photos"])
        // More than the 32-listing capability cache: scanning must not evict useful recents.
        for index in 0..<64 {
            let response = try await list(broker, source: source, path: "/photos/child\(index)")
            XCTAssertNil(response.error)
        }
        _ = try await list(broker, source: source, path: "/photos") // refresh or renewal
        XCTAssertEqual(catalog.recentLocations(from: []).map(\.path), ["/photos"])
        XCTAssertEqual(notifications.value, 0)
        // Empty directories and cache hits have no media token and need no second SFTP read.
        remember.path = "/photos/child0"
        XCTAssertNil(broker.handle(remember).error)
        remember.path = "/photos/"
        XCTAssertNil(broker.handle(remember).error)
        XCTAssertEqual(catalog.recentLocations(from: []).map(\.path), ["/photos"])
        XCTAssertEqual(catalog.recentLocations(from: []).first?.id, originalID)
        XCTAssertEqual(notifications.value, 0)
        let reloaded = RemoteServerCatalog(defaults: defaults)
        XCTAssertEqual(reloaded.recentLocations(from: []).map(\.path), ["/photos"])
        XCTAssertEqual(broker.handle(BridgeRequest("catalog")).locations?.first?.path, "/photos")
    }
    func testHistoryWritesRequireConsentCurrentProtocolKnownHostAndValidPath() throws {
        let (broker, catalog, defaults, _) = try fixture()
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        var request = BridgeRequest("rememberOpen"); request.sourceID = source.id; request.path = "/photos"
        for version in [1, 2, 3, 4, FrameBridgeEnvironment.protocolVersion + 1] {
            request.version = version
            XCTAssertNotNil(broker.handle(request).error)
            request.operation = "list"
            XCTAssertNotNil(broker.handle(request).error)
            request.operation = "rememberOpen"
        }
        request.version = FrameBridgeEnvironment.protocolVersion
        request.sourceID = "unknown"
        XCTAssertNil(broker.handle(request).error) // obsolete history endpoint is always a no-op
        request.sourceID = source.id
        for path in [nil, "relative", "/photos/../secret", "/photos\nsecret"] as [String?] {
            request.path = path
            XCTAssertNil(broker.handle(request).error)
        }
        request.path = "/photos"
        broker.revoke()
        XCTAssertNotNil(broker.handle(request).error)
        XCTAssertTrue(catalog.recentLocations(from: []).isEmpty)
    }
    func testFailedAndCancelledListingsLeaveExistingHistoryUntouched() async throws {
        let (broker, catalog, defaults, _) = try fixture()
        defer { broker.stop() }
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        var remember = BridgeRequest("rememberOpen"); remember.sourceID = source.id; remember.path = "/existing"
        XCTAssertNil(broker.handle(remember).error)
        catalog.recordSuccessfulOpen(try XCTUnwrap(catalog.servers(from: []).first), path: "/existing")
        let failed = try await list(broker, source: source, path: "/failure")
        XCTAssertNotNil(failed.error)
        var request = BridgeRequest("list"); request.sourceID = source.id; request.path = "/cancelled"
        let pending = broker.handle(request)
        var cancel = BridgeRequest("cancel"); cancel.jobID = pending.jobID
        _ = broker.handle(cancel)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(catalog.recentLocations(from: []).map(\.path), ["/existing"])
    }
    func testUnrecognizedHostTraversalAndExpiredHandoffRejected() throws {
        let (broker, _, defaults, _) = try fixture()
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        var request = BridgeRequest("list"); request.sourceID = "unknown"; request.path = "/photos"
        XCTAssertNotNil(broker.handle(request).error)
        request.sourceID = source.id; request.path = "/photos/../secrets"
        XCTAssertNotNil(broker.handle(request).error)
        var handoff = BridgeRequest("handoff"); handoff.nonce = UUID()
        XCTAssertNotNil(broker.handle(handoff).error)
    }
    func testLinkedFrameMutatesWithoutAdditionalPermissionOrHistoryChanges() async throws {
        let (broker, catalog, defaults, service) = try fixture()
        defer { broker.stop() }
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        let response = try await list(broker, source: source, path: "/photos")
        for operation in ["archive", "delete", "restore"] {
            var request = BridgeRequest(operation)
            request.listingID = response.listingID; request.root = "/photos"; request.name = "a.jpg"
            request.sourceID = source.id; request.recordID = UUID()
            var result = broker.handle(request)
            XCTAssertNil(result.error)
            var status = BridgeRequest("status"); status.jobID = try XCTUnwrap(result.jobID)
            for _ in 0..<100 where result.status == "pending" {
                try await Task.sleep(for: .milliseconds(1)); result = broker.handle(status)
            }
            XCTAssertEqual(result.status, "ready"); XCTAssertNil(result.error)
        }
        XCTAssertEqual(service.actions, ["archive", "delete", "restore"])
        XCTAssertTrue(catalog.recentLocations(from: []).isEmpty)
        XCTAssertNotNil(broker.handle(BridgeRequest("trash")).error)
        XCTAssertNotNil(broker.handle(BridgeRequest("authorizeWrites")).error)
    }
    func testExactSidecarOwnerCannotBeClaimedByAnotherStem() {
        let photo = BridgeEntry(name: "a.jpg", path: "/p/a.jpg", directory: false, size: 1, modified: "1")
        let other = BridgeEntry(name: "a.jpg.png", path: "/p/a.jpg.png", directory: false, size: 1, modified: "1")
        let json = BridgeEntry(name: "a.jpg.json", path: "/p/a.jpg.json", directory: false, size: 1, modified: "1")
        XCTAssertEqual(FrameBridgeBroker.companions(for: photo, entries: [photo, other, json]), [json])
        XCTAssertTrue(FrameBridgeBroker.companions(for: other, entries: [photo, other, json]).isEmpty)
    }
    func testHundredAssetBatchUsesOneHelperInvocationAndPairsJSON() async throws {
        let (broker, catalog, defaults, service) = try fixture()
        defer { broker.stop() }
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        service.assetCount = 100
        let source = try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first)
        let listing = try await list(broker, source: source, path: "/photos")
        var request = BridgeRequest("deleteBatch")
        request.sourceID = source.id; request.root = "/photos"
        request.targets = try listing.entries?.filter { $0.name.hasSuffix(".jpg") }.map {
            BridgeDeleteTarget(listingID: try XCTUnwrap(listing.listingID), path: $0.path)
        }
        var response = broker.handle(request)
        var status = BridgeRequest("status"); status.jobID = try XCTUnwrap(response.jobID)
        for _ in 0..<100 where response.status == "pending" {
            try await Task.sleep(for: .milliseconds(1)); response = broker.handle(status)
        }
        XCTAssertNil(response.error)
        XCTAssertEqual(response.asset?.outcomes?.count, 100)
        XCTAssertEqual(service.actions, ["deleteBatch"])
        XCTAssertEqual(service.batches.count, 1)
        XCTAssertEqual(service.batches.first?.count, 100)
        XCTAssertTrue(service.batches[0].allSatisfy { $0.members.count == 4 })
        XCTAssertTrue(catalog.recentLocations(from: []).isEmpty)
        request.targets?[0].path = "/elsewhere/no.jpg"
        XCTAssertNotNil(broker.handle(request).error)
        XCTAssertEqual(service.batches.count, 1)
    }
    func testDisposableLoopbackReadOnlyTransfer() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["FRAME_BRIDGE_SFTP_PROOF_DIR"] else {
            throw XCTSkip("Set FRAME_BRIDGE_SFTP_PROOF_DIR to the disposable loopback fixture.")
        }
        let service = SFTPRemoteFileService(executableURL: URL(fileURLWithPath: fixture + "/sftp-fixture"), connectionSharing: false)
        defer { service.shutdown() }
        let server = RemoteServer(id: UUID(), name: "Fixture", sshHost: NSUserName() + "@127.0.0.1", additionalArguments: [
            "-p", "31298", "-i", fixture + "/client_key",
            "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5"
        ])
        let entries = try await service.list(server: server, path: fixture + "/media")
        XCTAssertEqual(Set(entries.map(\.name)), ["fixture.jpg", "fixture.jpg.json"])
        for entry in entries {
            let local = try await service.preparePreviewWithProgress(server: server, entry: entry) { _ in }
            defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
            XCTAssertEqual(try Data(contentsOf: local), try Data(contentsOf: URL(fileURLWithPath: fixture + "/media/" + entry.name)))
        }
    }
}

private final class BridgeServiceFixture: RemoteFileServing, @unchecked Sendable {
    var actions: [String] = []
    var assetCount = 1
    var batches: [[BridgeAssetInput]] = []
    func frameAsset(server: RemoteServer, input: BridgeAssetInput) async throws -> BridgeAssetResult {
        if input.action == "deleteBatch" {
            actions.append(input.action); batches.append(input.batch ?? [])
            var result = BridgeAssetResult()
            result.outcomes = input.batch?.map { BridgeDeleteOutcome(path: $0.members[0].path) }
            return result
        }
        if ["archive", "delete", "restore"].contains(input.action) {
            actions.append(input.action)
            if input.action != "restore" { XCTAssertEqual(input.members.map(\.name), ["a.jpg"]) }
            return BridgeAssetResult()
        }
        guard input.action == "list" else { throw BridgeError("No asset action expected") }
        let entries = try await list(server: server, path: input.root)
        var result = BridgeAssetResult()
        result.entries = entries.filter { $0.kind != .symbolicLink }.map {
            BridgeEntry(name: $0.name, path: $0.path, directory: $0.isDirectory, size: $0.size ?? 0, modified: $0.modificationText)
        }
        return result
    }
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        if path == "/failure" { throw BridgeError("Fixture folder unavailable") }
        if assetCount > 1 {
            return (0..<assetCount).flatMap { index in
                ["\(index).jpg", "\(index).prompt.json", "\(index).xyz.json", "\(index).qqq.txt"].map {
                    RemoteFileEntry(name: $0, path: path + "/" + $0, kind: .file, size: 12, modificationText: "fixture")
                }
            }
        }
        return [RemoteFileEntry(name: "a.jpg", path: path + "/a.jpg", kind: .file, size: 12, modificationText: "fixture"),
         RemoteFileEntry(name: "link.jpg", path: path + "/link.jpg", kind: .symbolicLink, size: 12, modificationText: "fixture")]
    }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        XCTFail("No download expected"); throw BridgeError("No download expected")
    }
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        XCTFail("No preview expected"); throw BridgeError("No preview expected")
    }
}

private final class HistoryNotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
