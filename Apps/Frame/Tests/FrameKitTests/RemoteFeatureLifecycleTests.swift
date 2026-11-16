import BridgeProtocol
import Composition
import XCTest
@testable import FrameKit

@MainActor
final class RemoteFeatureLifecycleTests: XCTestCase {
    private let source = BridgeSource(id: String(repeating: "a", count: 64), name: "Feature fixture")
    private func photos(_ path: String = "/photos", count: Int = 3) -> [PhotoItem] {
        (0..<count).map { index in
            PhotoItem(id: "\(path)/\(index).jpg", rootID: UUID(), url: URL(fileURLWithPath: "/fixture/\(index).jpg"),
                relativePath: "\(path)/\(index).jpg", folderRelativePath: path, name: "\(index).jpg", format: .jpeg,
                fileSize: 1, createdAt: nil, modifiedAt: nil, fileIdentifier: nil)
        }
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Feature transition did not reach its synchronization point")
        throw BridgeError("Fixture timeout")
    }

    func testDeleteWithdrawalDrainsSubmittedBatchAndDoesNotReplayConfirmedOutcomes() async throws {
        let gate = remoteFeatureGate(), calls = RemoteFeatureCalls(), photos = photos()
        addTeardownBlock { await gate.release() }
        let actions = FixtureRemoteActions(deletion: { photos, _ in
            await calls.record("delete")
            await gate.wait()
            return [FileActionFailure(photo: photos[1], reason: "Permission denied")]
        })
        let composition = actions.composition()
        try await composition.start()
        let feature = try XCTUnwrap(composition.files.remoteDelete)
        let localGeneration = composition.active("preview.image")?.generation
        let operation = Task { try await feature.delete(photos, root: "/photos") }
        try await gate.waitFor()
        var drained = false
        let disable = Task {
            try await composition.exclude("remote/delete", true)
            drained = true
        }
        try await waitFor { !feature.isActive }
        XCTAssertFalse(drained)
        XCTAssertFalse(composition.files.canRemoteDelete)
        XCTAssertTrue(composition.files.canRemoteArchive)
        await gate.release()
        let receipt = try await operation.value
        try await disable.value
        XCTAssertEqual(receipt.removed, [photos[0].id, photos[2].id])
        XCTAssertEqual(receipt.failures.map { $0.photo.id }, [photos[1].id])
        XCTAssertEqual(composition.files.undoCount, 0, "Remote deletion never creates local Undo history")
        try await composition.exclude("remote/delete", false)
        XCTAssertTrue(composition.files.canRemoteDelete)
        do { _ = try await feature.delete(photos, root: "/photos"); XCTFail("Retired delete context accepted new work") } catch {}
        let invocations = await calls.values
        XCTAssertEqual(invocations, ["delete"], "Reactivation must not replay a mutation")
        XCTAssertEqual(composition.active("preview.image")?.generation, localGeneration)
        await composition.stop()
    }

    func testArchiveCancellationStopsNextItemAndRetainsSubmittedOutcome() async throws {
        let gate = remoteFeatureGate(), calls = RemoteFeatureCalls(), photos = photos()
        addTeardownBlock { await gate.release() }
        let actions = FixtureRemoteActions(mutation: { photo, action, _ in
            await calls.record(action + ":" + photo.id)
            await gate.wait()
            return UUID()
        })
        let session = FixedRemoteSession(PartialRemoteSession(actions: actions))
        let composition = FrameComposition(remoteSession: session)
        try await composition.start()
        let feature = try XCTUnwrap(composition.files.remoteArchive)
        let operation = Task { try await feature.apply(photos, root: "/photos", restoring: false) { _ in } }
        try await gate.waitFor()
        feature.cancel()
        await gate.release()
        let result = try await operation.value
        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.removed, [photos[0].id])
        XCTAssertTrue(result.failures.isEmpty)
        let callsAfterCancel = await calls.values
        XCTAssertEqual(callsAfterCancel, ["archive:" + photos[0].id])
        session.withdraw()
        XCTAssertFalse(composition.files.canRemoteArchive, "Withdrawal is visible before any cleanup has run")
        await composition.runtime.settled()
        XCTAssertFalse(composition.files.canRemoteArchive)
        XCTAssertFalse(composition.files.canRemoteDelete)
        XCTAssertTrue(composition.files.canArchive)
        XCTAssertTrue(composition.files.canTrash)
        session.restore()
        await composition.runtime.settled()
        XCTAssertTrue(composition.files.canRemoteArchive)
        let callsAfterReenable = await calls.values
        XCTAssertEqual(callsAfterReenable, callsAfterCancel)
        await composition.stop()
    }

    func testRemoteExportWithdrawalJoinsDownloadAndRejectsLateFile() async throws {
        let gate = remoteFeatureGate(), photo = photos(count: 1)[0]
        addTeardownBlock { await gate.release() }
        let provider = FixtureRemoteFiles(resolveFile: { _, companions, video, _ in
            XCTAssertTrue(companions); XCTAssertTrue(video)
            await gate.wait()
            return photo
        })
        let composition = FrameComposition.fixture(files: provider)
        try await composition.start()
        let feature = try XCTUnwrap(composition.files.remoteExporter)
        let download = Task { try await feature.resolve(photo) }
        try await gate.waitFor()
        var drained = false
        let disable = Task {
            try await composition.exclude("remote/export", true)
            drained = true
        }
        try await waitFor { !feature.isActive }
        XCTAssertFalse(drained)
        await gate.release()
        do { _ = try await download.value; XCTFail("Retired export opened a downloaded file") } catch {}
        try await disable.value
        XCTAssertTrue(composition.files.canTrash)
        XCTAssertTrue(composition.files.canArchive)
        await composition.stop()
    }

    func testRemoteLibraryOwnsOldTreeUntilSupersededReadFinishes() async throws {
        let gate = remoteFeatureGate(), old = photos("/old", count: 1), new = photos("/new", count: 1)
        addTeardownBlock { await gate.release() }
        let store = makeRemoteStore(remoteFolderLoader: { _, path in
            if path == "/old" { await gate.wait() }
            return ScanResult(photos: path == "/old" ? old : new,
                rootFolder: FolderNode(id: path, name: path, relativePath: path, photoCount: 1, children: []))
        })
        let first = Task { await store.openRemote(source, path: "/old") }
        try await gate.waitFor()
        let previous = try XCTUnwrap(store.remoteFolders)
        await store.openRemote(source, path: "/new")
        XCTAssertTrue(previous.isStopped)
        XCTAssertEqual(store.photos.map(\.id), new.map(\.id))
        var drained = false
        let shutdown = Task { await store.shutdown(); drained = true }
        try await waitFor { !store.previews.remoteLibrary.isAvailable }
        XCTAssertFalse(drained, "The old tree must remain owned after navigation replaces it")
        await gate.release()
        await shutdown.value
        await first.value
        XCTAssertEqual(store.photos.map(\.id), new.map(\.id))
        XCTAssertTrue(previous.files(at: "/old").isEmpty)
        XCTAssertTrue(store.previews.runtime.statuses.isEmpty)
    }

    func testLibraryWithdrawalRejectsCachedReadsAndKeepsLocalFeaturesAvailable() async throws {
        let photos = photos(count: 1)
        let store = makeRemoteStore(remoteFolderLoader: { _, path in
            ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: path, relativePath: path, photoCount: 1, children: []))
        })
        await store.openRemote(source, path: "/photos")
        let tree = try XCTUnwrap(store.remoteFolders)
        try await store.previews.exclude("remote/library", true)
        XCTAssertTrue(tree.isStopped)
        do { _ = try await tree.load("/photos"); XCTFail("Cached reads retained withdrawn authority") } catch {}
        XCTAssertEqual(store.photos.map(\.id), photos.map(\.id), "Keep the last good presentation")
        XCTAssertFalse(store.canDelete)
        XCTAssertTrue(store.previews.files.canTrash)
        XCTAssertTrue(store.previews.files.canExport)
        try await store.previews.exclude("remote/library", false)
        await store.openRemote(source, path: "/photos")
        XCTAssertFalse(store.remoteFolders === tree)
        await store.shutdown()
    }

    func testRecursiveScanIsOwnedByLibraryAndCannotPublishAfterWithdrawal() async throws {
        let gate = remoteFeatureGate(), photos = photos(count: 1)
        addTeardownBlock { await gate.release() }
        let store = makeRemoteStore(remoteFolderLoader: { _, path in
            if path != "/photos" { await gate.wait() }
            let children = path == "/photos" ? [FolderNode(id: "/photos/child", name: "child", relativePath: "/photos/child", photoCount: 1, children: [])] : []
            return ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: path, relativePath: path, photoCount: 1, children: children))
        })
        await store.openRemote(source, path: "/photos")
        await store.setIncludesSubfolders(true)
        try await gate.waitFor()
        let before = store.photos.map(\.id)
        var drained = false
        let disable = Task {
            try await store.previews.exclude("remote/library", true)
            drained = true
        }
        try await waitFor { !store.previews.remoteLibrary.isAvailable }
        XCTAssertFalse(drained)
        XCTAssertTrue(store.remoteFolders?.isStopped == true, "All child reads stop before joining the recursive scan")
        await gate.release()
        try await disable.value
        try await waitFor { !store.isScanningSubfolders }
        XCTAssertEqual(store.photos.map(\.id), before)
        XCTAssertFalse(store.canDelete)
        await store.shutdown()
    }

    func testSessionWithdrawalRejectsLateCatalogAndCachedListingAtOnce() async throws {
        let gate = remoteFeatureGate(), photos = photos(count: 1)
        addTeardownBlock { await gate.release() }
        let service = FixtureRemoteLibrary(readCatalog: { await gate.wait(); return BridgeResponse() }, loader: { _, path in
            ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: path, relativePath: path, photoCount: 1, children: []))
        })
        let session = FixedRemoteSession(PartialRemoteSession(library: service))
        let composition = FrameComposition(remoteSession: session)
        try await composition.start()
        let feature = try XCTUnwrap(composition.remoteLibrary.feature)
        let tree = try feature.makeIndex(source: source, path: "/photos")
        _ = try await tree.load("/photos")
        let catalog = Task { try await feature.catalog() }
        try await gate.waitFor()
        // Withdrawal is synchronous: the feature refuses work before any cleanup has run.
        session.withdraw()
        XCTAssertFalse(feature.isActive)
        XCTAssertFalse(composition.remoteLibrary.isAvailable)
        XCTAssertFalse(composition.remoteAvailable)
        do { _ = try await tree.load("/photos"); XCTFail("Warm cache bypassed revoked authority") } catch {}
        await gate.release()
        do { _ = try await catalog.value; XCTFail("Late catalog bypassed revoked authority") } catch {}
        await composition.stop()
    }

    func testSessionWithdrawalRejectsLateExportAtOnce() async throws {
        let gate = remoteFeatureGate(), photo = photos(count: 1)[0]
        addTeardownBlock { await gate.release() }
        let service = FixtureRemoteFiles(resolveFile: { _, _, _, _ in await gate.wait(); return photo })
        let session = FixedRemoteSession(PartialRemoteSession(files: service))
        let composition = FrameComposition(remoteSession: session)
        try await composition.start()
        let feature = try XCTUnwrap(composition.files.remoteExporter)
        let download = Task { try await feature.resolve(photo) }
        try await gate.waitFor()
        session.withdraw()
        XCTAssertFalse(feature.isActive)
        await gate.release()
        do { _ = try await download.value; XCTFail("Late download bypassed revoked authority") } catch {}
        await composition.stop()
    }
}

private func remoteFeatureGate() -> KeyedGate { KeyedGate(failure: "Fixture operation did not start", timeout: BridgeError("Fixture timeout")) }

private actor RemoteFeatureCalls {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private struct FixtureRemoteFiles: RemoteFileReading {
    let resolveFile: @Sendable (PhotoItem, Bool, Bool, Int) async throws -> PhotoItem
    func resolve(_ photo: PhotoItem, includeCompanions: Bool, allowVideo: Bool, priority: Int) async throws -> PhotoItem {
        try await resolveFile(photo, includeCompanions, allowVideo, priority)
    }
    func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry] { [] }
    func cachedMedia(_ photo: PhotoItem) async -> PhotoItem? { nil }
    func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText] { [] }
    func pin(_ photo: PhotoItem?) async {}
}
