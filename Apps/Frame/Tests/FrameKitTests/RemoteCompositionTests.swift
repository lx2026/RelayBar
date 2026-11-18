import AppKit
import BridgeProtocol
import Composition
import XCTest
@testable import FrameKit

private actor LinkFixture {
    enum Mode { case ready, revoked, incompatible, helperMissing }
    var mode = Mode.ready
    var requests: [String] = []
    var holdList = false
    var holdCatalog = false
    var holdDelete = false
    var pending: CheckedContinuation<Void, Never>?
    let source = BridgeSource(id: String(repeating: "a", count: 64), name: "Fixture")
    func set(_ mode: Mode) { self.mode = mode }
    func hold() { holdList = true }
    func holdDiscovery() { holdCatalog = true }
    func holdMutation() { holdDelete = true }
    func isWaiting() -> Bool { pending != nil }
    func release() { holdList = false; holdDelete = false; holdCatalog = false; pending?.resume(); pending = nil }
    func count(_ operation: String) -> Int { requests.filter { $0 == operation }.count }
    func send(_ request: BridgeRequest) async throws -> BridgeResponse {
        requests.append(request.operation)
        if mode == .revoked {
            return BridgeResponse(error: "Open a folder in RelayBar and choose Open in Frame to allow remote viewing.", sessionFailure: .unauthorized)
        }
        if mode == .incompatible { var response = BridgeResponse(); response.version = 5; return response }
        var response = BridgeResponse()
        switch request.operation {
        case "catalog":
            if holdCatalog { await withCheckedContinuation { pending = $0 } }
            response.sources = [source]; response.locations = []
        case "list":
            if holdList { await withCheckedContinuation { pending = $0 } }
            response.listingID = UUID()
            response.entries = [BridgeEntry(name: "image.png", path: "/images/image.png", directory: false, size: 10, modified: "1")]
        case "preview":
            if mode == .helperMissing { return BridgeResponse(error: "Preview helper unavailable.") }
            var asset = BridgeAssetResult()
            asset.image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2+XQAAAAASUVORK5CYII=")
            asset.fingerprint = "fixture"
            response.asset = asset
        case "archive": response.error = "File is no longer available."
        case "deleteBatch":
            if holdDelete { await withCheckedContinuation { pending = $0 } }
            var asset = BridgeAssetResult()
            asset.outcomes = request.targets?.map { BridgeDeleteOutcome(path: $0.path) }
            response.asset = asset
        default: break
        }
        return response
    }
}

private actor SocketCalls {
    private(set) var operations: [String] = []
    private(set) var connections: Set<UUID> = []
    private(set) var gone: Set<UUID> = []
    func record(_ operation: String, _ connection: UUID) { operations.append(operation); connections.insert(connection) }
    func disconnected(_ connection: UUID) { gone.insert(connection) }
}

@MainActor
final class RemoteCompositionTests: XCTestCase {
    func testRepeatedWithdrawalAndProviderRemovalDrainCachedReadersBeforeCleanup() async throws {
        // The session ends either because RelayBar withdrew it or because the link itself was removed.
        for removedEntry in [nil, "relay.link"] as [String?] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameCachedRead-\(UUID())")
            let job = UUID()
            // The transfer receipt's directory must match its job identity.
            let receipt = root.appendingPathComponent("FrameTransfers-fixture/\(job)")
            try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
            let sourceVideo = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/landscape.mp4")
            let bytes = try Data(contentsOf: sourceVideo)
            try bytes.write(to: receipt.appendingPathComponent("video.mp4"))
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let source = BridgeSource(id: String(repeating: "a", count: 64), name: "Cached read fixture")
            let link = FrameRemoteLink(transport: { request in
                var response = BridgeResponse()
                if request.operation == "catalog" { response.sources = [source]; response.locations = [] }
                if request.operation == "list" {
                    response.listingID = UUID()
                    response.entries = [BridgeEntry(name: "video.mp4", path: "/media/video.mp4", directory: false,
                        size: Int64(bytes.count), modified: "1")]
                }
                if request.operation == "fetch" {
                    response.jobID = job; response.cacheRelativePath = "FrameTransfers-fixture/\(job)/video.mp4"
                }
                return response
            }, sharedRoot: { root })
            let gate = CachedReadGate()
            addTeardownBlock { await gate.release() }
            var operations = FrameMediaOperations()
            operations.metadata = { photo, client, preview, reader in
                if let local = await client?.cachedMedia(photo) { await gate.wait(local.url) }
                return await ImageMetadataReader.read(photo: photo, remoteClient: client, remotePreview: preview, videoMetadata: reader)
            }
            let features = FrameComposition(link: link, mediaFeatures: FrameMediaFeatures(operations: operations))
            _ = try await features.client.catalog()
            let photo = try await features.client.list(source: source, path: "/media").photos[0]
            let local = try await features.client.resolve(photo, includeCompanions: false, allowVideo: true, priority: 0)
            let feature = try XCTUnwrap(features.media.remoteMetadata)
            let read = Task { try await feature.read(photo) }
            for _ in 0..<500 {
                if await gate.url != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let heldURL = await gate.url
            XCTAssertEqual(heldURL, local.url)
            var drained = false
            let retirement: Task<Void, Error>
            if let removedEntry {
                retirement = Task {
                    try await features.exclude(removedEntry, true)
                    drained = true
                }
            } else {
                link.withdraw("First withdrawal")
                link.withdraw("Repeated withdrawal before reconciliation")
                retirement = Task { await link.settle(); drained = true }
            }
            for _ in 0..<100 where feature.isActive { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(feature.isActive)
            XCTAssertFalse(drained)
            XCTAssertEqual(try? Data(contentsOf: local.url), bytes, "A dependent decoder still owns these cached bytes")
            await gate.release()
            do { _ = try await read.value; XCTFail("Retired cached reader escaped withdrawal") } catch {}
            try await retirement.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.url.path))
            XCTAssertNil(features.active("remote/metadata"))
            if let removedEntry {
                try await features.exclude(removedEntry, false)
            }
            try await link.connect()
            XCTAssertNotNil(features.media.remoteMetadata)
            let reopened = try await features.client.list(source: source, path: "/media").photos[0]
            let fresh = try await features.client.resolve(reopened, includeCompanions: false, allowVideo: true, priority: 0)
            XCTAssertEqual(try Data(contentsOf: fresh.url), bytes)
            XCTAssertNotEqual(fresh.url, local.url)
            await features.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.url.path))
        }
    }

    func testVisibilitySaveFailurePreservesSessionAndSuccessfulSaveWithdrawsAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameVisibility-\(UUID())")
        let suite = "FrameVisibility.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("preferences.json")
        let fixture = LinkFixture(), link = FrameRemoteLink(transport: { try await fixture.send($0) })
        let composition = FrameComposition(link: link, preferencesURL: storage)
        let store = LibraryStore(defaults: defaults, previews: composition)
        await store.openRemote(fixture.source, path: "/images")
        let photo = try XCTUnwrap(store.selectedPhoto)
        let session = try XCTUnwrap(composition.active("remote/source")?.generation)
        let local = try XCTUnwrap(composition.active("preview.image")?.generation)
        try FileManager.default.createDirectory(at: storage.appendingPathExtension("previous"), withIntermediateDirectories: true)
        await store.setShowsRemoteFolders(false)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.showsRemoteFolders)
        XCTAssertTrue(link.isConnected)
        XCTAssertEqual(store.selectedPhoto?.id, photo.id)
        XCTAssertEqual(composition.active("remote/source")?.generation, session)
        try FileManager.default.removeItem(at: storage.appendingPathExtension("previous"))
        store.errorMessage = nil
        await store.setShowsRemoteFolders(false)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.showsRemoteFolders)
        XCTAssertFalse(link.isConnected)
        XCTAssertNil(store.selectedPhoto)
        do { _ = try await composition.image(photo, pixels: 128); XCTFail("Hidden remote preference retained authority") } catch {}
        await link.settle()
        XCTAssertNil(composition.active("remote/source"))
        XCTAssertEqual(composition.active("preview.image")?.generation, local)
        await store.shutdown()
        let reopened = LibraryStore(defaults: defaults, previews: FrameComposition(preferencesURL: storage))
        try await reopened.previews.start()
        XCTAssertFalse(reopened.showsRemoteFolders)
        XCTAssertEqual(reopened.previews.link.state, .hidden)
        await reopened.shutdown()
    }

    func testShutdownDrainsDiscoveryAndLateRequestsCannotReopenComposition() async throws {
        let fixture = LinkFixture(), link = FrameRemoteLink(transport: { try await fixture.send($0) })
        addTeardownBlock { await fixture.release() }
        let features = FrameComposition(link: link)
        try await features.start()
        await fixture.holdDiscovery()
        let connect = Task { try await link.connect() }
        for _ in 0..<500 {
            if await fixture.isWaiting() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = await fixture.isWaiting(); XCTAssertTrue(entered)
        var drained = false
        let shutdown = Task { await features.stop(); drained = true }
        for _ in 0..<500 where features.active("metadata") != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(features.active("metadata"))
        XCTAssertFalse(drained)
        await fixture.release()
        do { try await connect.value; XCTFail("Discovery survived shutdown") } catch {}
        await shutdown.value
        XCTAssertTrue(features.runtime.statuses.isEmpty)
        do { _ = try await features.client.catalog(); XCTFail("Late catalog reopened composition") } catch {}
        XCTAssertTrue(features.runtime.statuses.isEmpty)
        try await features.start() // Explicit composition restart remains supported.
        try await link.connect()
        XCTAssertTrue(link.isConnected)
        await features.stop()
        XCTAssertTrue(features.runtime.statuses.isEmpty)
    }

    func testSubmittedDeleteWithdrawsWithoutClaimingUndoOrReplayingOnReconnect() async throws {
        let fixture = LinkFixture(), link = FrameRemoteLink(transport: { try await fixture.send($0) })
        addTeardownBlock { await fixture.release() }
        let composition = FrameComposition(link: link), store = LibraryStore(previews: composition)
        await store.openRemote(fixture.source, path: "/images")
        XCTAssertTrue(store.canDelete)
        await fixture.holdMutation()
        let deletion = Task { await store.deleteSelection() }
        for _ in 0..<100 {
            if await fixture.isWaiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await fixture.isWaiting(); XCTAssertTrue(waiting)
        link.withdraw("Disconnected during deletion.")
        var drained = false
        let retirement = Task { await link.settle(); drained = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained)
        XCTAssertFalse(store.canDelete)
        await fixture.release()
        await deletion.value
        await retirement.value
        XCTAssertEqual(store.fileActionFailures.count, 1)
        XCTAssertTrue(store.fileActionFailures.first?.reason.contains("Refresh") == true)
        XCTAssertEqual(store.photos.count, 1, "Uncertain deletion must not be presented as a confirmed success")
        XCTAssertFalse(store.canUndoTrash)
        await store.openRemote(fixture.source, path: "/images")
        XCTAssertTrue(store.canDelete)
        let calls = await fixture.count("deleteBatch")
        XCTAssertEqual(calls, 1)
        await store.shutdown()
    }

    func testAuthenticatedCapabilitiesWithdrawAndReactivateWithoutAffectingLocalPreviews() async throws {
        let fixture = LinkFixture(), link = FrameRemoteLink(transport: { try await fixture.send($0) })
        let features = FrameComposition(link: link)
        try await features.start()
        XCTAssertNil(features.active("remote/library"))
        let localID = try XCTUnwrap(features.active("preview.image")).generation
        _ = try await features.client.catalog()
        let firstID = try XCTUnwrap(features.active("remote/library")).generation
        let scan = try await features.client.list(source: fixture.source, path: "/images")
        let photo = try XCTUnwrap(scan.photos.first)
        let preview = try await features.image(photo, pixels: 128)
        XCTAssertNotNil(preview.content.image)
        link.withdraw("Fixture connection ended.")
        let catalogBeforeThumbnail = await fixture.count("catalog")
        do { _ = try await features.image(photo, pixels: 128); XCTFail("Thumbnail reconnected on its own") } catch {}
        let catalogAfterThumbnail = await fixture.count("catalog")
        XCTAssertEqual(catalogBeforeThumbnail, catalogAfterThumbnail)
        do { _ = try await features.client.preview(photo, pixels: 128); XCTFail("Stale remote authority survived") } catch {}
        await link.settle()
        XCTAssertTrue(preview.isClosed)
        XCTAssertTrue(features.remoteRegistry.descriptors.isEmpty)
        XCTAssertNil(features.active("remote/library"))
        XCTAssertEqual(features.active("preview.image")?.generation, localID)
        _ = try await features.client.catalog()
        XCTAssertNotEqual(features.active("remote/library")?.generation, firstID)
        XCTAssertEqual(features.active("preview.image")?.generation, localID)
        await features.stop()
        XCTAssertTrue(features.runtime.statuses.isEmpty)
    }

    func testWithdrawalDrainsDelayedReadRejectsLateResultAndDoesNotReplayMutation() async throws {
        let fixture = LinkFixture(), link = FrameRemoteLink(transport: { try await fixture.send($0) })
        let features = FrameComposition(link: link)
        _ = try await features.client.catalog()
        let scan = try await features.client.list(source: fixture.source, path: "/images")
        let photo = try XCTUnwrap(scan.photos.first)
        await fixture.hold()
        let read = Task { try await features.client.list(source: fixture.source, path: "/images") }
        for _ in 0..<100 {
            if await fixture.isWaiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await fixture.isWaiting(); XCTAssertTrue(waiting)
        link.withdraw("Disconnected during a read.")
        var drained = false
        let retirement = Task { await link.settle(); drained = true }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(drained)
        do { _ = try await features.client.mutate(photo, action: "archive", root: "/images"); XCTFail("Mutation accepted while withdrawn") } catch {}
        await fixture.release()
        do { _ = try await read.value; XCTFail("Late read escaped withdrawal") } catch {}
        await retirement.value
        _ = try await features.client.catalog()
        let mutationCount = await fixture.count("archive")
        XCTAssertEqual(mutationCount, 0)
        await features.stop()
    }

    /// Wire v7 against a real socket: one connection per session, and its end is the withdrawal.
    func testRelayBarGoingAwayWithdrawsTheSessionWithoutPollingAndReconnects() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("frame-link-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("viewer.sock"), calls = SocketCalls()
        let source = BridgeSource(id: String(repeating: "c", count: 64), name: "Socket fixture")
        func serve() throws -> BridgeSocketServer {
            try BridgeSocketServer(url: url, verifyPeer: { _ in }, onDisconnect: { id in Task { await calls.disconnected(id) } }) { request, connection in
                await calls.record(request.operation, connection)
                var response = BridgeResponse()
                if request.operation == "catalog" { response.sources = [source]; response.locations = [] }
                return response
            }
        }
        var server = try serve()
        let link = FrameRemoteLink(connector: FrameRemoteLink.socket(url, verifyPeer: { _ in }), automaticallyConnect: true)
        let features = FrameComposition(link: link)
        try await features.start()
        try await link.connect()
        XCTAssertTrue(link.isConnected)
        XCTAssertNotNil(features.active("remote/library"))
        let local = try XCTUnwrap(features.active("thumbnails")?.generation)
        _ = try await features.client.catalog()
        let before = await calls.operations

        // RelayBar goes away. Nothing is requested; the connection ending is the signal.
        let start = ContinuousClock.now
        await server.close()
        for _ in 0..<500 where link.isConnected { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(link.isConnected)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1), "Far inside the old three-second liveness interval")
        XCTAssertFalse(features.remoteAvailable)
        await link.settle()
        XCTAssertNil(features.active("remote/library"))
        XCTAssertEqual(features.active("thumbnails")?.generation, local, "Local features are untouched")
        let after = await calls.operations
        XCTAssertEqual(after, before, "No request was needed to notice")

        // RelayBar returns at the same endpoint; a new session uses a new connection.
        server = try serve()
        try await link.connect()
        XCTAssertTrue(link.isConnected)
        XCTAssertNotNil(features.active("remote/library"))
        let connections = await calls.connections
        XCTAssertEqual(connections.count, 2)

        // Frame going away is seen by RelayBar's side at once.
        await features.stop()
        for _ in 0..<500 {
            if await calls.gone.count == 2 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let gone = await calls.gone
        XCTAssertEqual(gone, connections)
        await server.close()
    }

    func testRevocationMismatchHiddenFoldersAndHelperAbsence() async throws {
        let fixture = LinkFixture(), link = FrameRemoteLink(transport: { try await fixture.send($0) })
        let features = FrameComposition(link: link)
        _ = try await features.client.catalog()
        let scan = try await features.client.list(source: fixture.source, path: "/images")
        let photo = try XCTUnwrap(scan.photos.first)
        await fixture.set(.helperMissing)
        do { _ = try await features.client.preview(photo, pixels: 128); XCTFail("Missing helper produced preview") } catch {}
        XCTAssertTrue(link.isConnected)
        XCTAssertNotNil(features.active("remote.access"))
        _ = try await features.client.list(source: fixture.source, path: "/images")
        await fixture.set(.revoked)
        do { _ = try await features.client.catalog(); XCTFail("Revoked session accepted") } catch {}
        await link.settle()
        XCTAssertFalse(link.isConnected)
        XCTAssertNil(features.active("remote.access"))
        await fixture.set(.incompatible)
        do { _ = try await features.client.catalog(); XCTFail("Incompatible protocol accepted") } catch {}
        await link.settle()
        XCTAssertFalse(link.isConnected)
        await fixture.set(.ready)
        _ = try await features.client.catalog()
        try await features.updatePreferences { $0.showsRemoteFolders = false }
        await link.settle()
        let prior = await fixture.count("catalog")
        do { _ = try await features.client.catalog(); XCTFail("Hidden remote folders reconnected") } catch {}
        let after = await fixture.count("catalog"); XCTAssertEqual(prior, after)
        try await features.updatePreferences { $0.showsRemoteFolders = true }
        _ = try await features.client.catalog()
        XCTAssertTrue(link.isConnected)
        await features.stop()
    }
}

private actor CachedReadGate {
    private(set) var url: URL?
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(_ url: URL) async {
        self.url = url
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor LateReceiptFixture {
    private var continuation: CheckedContinuation<BridgeResponse, Never>?
    private(set) var released: [UUID] = []
    var isWaiting: Bool { continuation != nil }
    func send(_ request: BridgeRequest) async -> BridgeResponse {
        if request.operation == "release", let id = request.jobID { released.append(id); return BridgeResponse() }
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ id: UUID) {
        var response = BridgeResponse(); response.jobID = id; response.status = "pending"
        continuation?.resume(returning: response); continuation = nil
    }
}

extension RemoteCompositionTests {
    func testCancelledRequestReleasesAJobReceiptThatArrivesLate() async throws {
        let fixture = LateReceiptFixture()
        let client = RelayRemoteClient(transport: { await fixture.send($0) })
        let task = Task { try await client.list(source: BridgeSource(id: String(repeating: "a", count: 64), name: "Fixture"), path: "/images") }
        for _ in 0..<100 {
            if await fixture.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await fixture.isWaiting; XCTAssertTrue(waiting)
        task.cancel()
        let job = UUID()
        await fixture.complete(job)
        do { _ = try await task.value; XCTFail("Cancelled request returned content") } catch {}
        await client.shutdown()
        let released = await fixture.released
        XCTAssertEqual(released, [job])
    }
}
