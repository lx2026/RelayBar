import AppKit
import BridgeProtocol
import Composition
import SwiftData
import XCTest
@testable import FrameKit

@MainActor
final class LocalAccessFeatureTests: XCTestCase {
    private func folder(_ name: String = "image.png") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameAccess-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2+XQAAAAASUVORK5CYII=")!
        try bytes.write(to: root.appendingPathComponent(name))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Local access did not reach its synchronization point"); throw CancellationError()
    }
    private func store(_ recorder: ScopeRecorder, gate: KeyedGate) throws -> (LibraryStore, ModelContainer) {
        let suite = "FrameAccess.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var operations = FrameMediaOperations()
        operations.metadata = { photo, client, preview, reader in
            var metadata = await ImageMetadataReader.read(photo: photo, remoteClient: client, remotePreview: preview, videoMetadata: reader)
            metadata.identity.append(MetadataRow(label: "Fixture", value: photo.name))
            await gate.wait(photo.name)
            return metadata
        }
        let composition = FrameComposition(mediaFeatures: FrameMediaFeatures(operations: operations),
            libraryFeatures: FrameLibraryFeatures(accessOperations: recorder.operations))
        let store = LibraryStore(defaults: defaults, previews: composition)
        let model = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        addTeardownBlock { await gate.releaseAll(); await store.shutdown(); _ = model }
        return (store, model)
    }

    func testSwitchingRootsKeepsOldBookmarkScopeUntilCancelledMetadataFinishes() async throws {
        let first = try folder("a.png"), second = try folder("b.png"), recorder = ScopeRecorder(), gate = accessReadGate()
        let (store, model) = try store(recorder, gate: gate)
        await store.start(modelContext: model.mainContext)
        await store.openRoot(first)
        try await gate.waitFor("a.png")
        let old = try XCTUnwrap(store.selectedPhoto)
        XCTAssertEqual(recorder.active(first), 1, "Index and metadata borrow the bookmarked root, not separate file URLs")
        await store.openRoot(second)
        try await gate.waitFor("b.png")
        XCTAssertEqual(recorder.active(first), 1, "The replaced metadata caller still uses this root")
        XCTAssertEqual(recorder.active(second), 1)
        do { _ = try await store.previews.media.readMetadata(old); XCTFail("Retired root admitted new media work") } catch {}
        await gate.release("a.png")
        try await waitFor { recorder.active(first) == 0 }
        XCTAssertFalse(store.metadata.identity.contains { $0.value == "a.png" })
        await gate.release("b.png")
        try await waitFor { store.metadata.identity.contains { $0.value == "b.png" } }
        XCTAssertEqual(store.rootURL?.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
        await store.shutdown()
        XCTAssertEqual(recorder.liveCount, 0)
        XCTAssertEqual(recorder.starts(first), 1)
        XCTAssertEqual(recorder.starts(second), 1)
    }

    func testShutdownWaitsForEveryBorrowAcrossSupersededRoots() async throws {
        let first = try folder("a.png"), second = try folder("b.png"), recorder = ScopeRecorder(), gate = accessReadGate()
        let (store, model) = try store(recorder, gate: gate)
        await store.start(modelContext: model.mainContext)
        await store.openRoot(first); try await gate.waitFor("a.png")
        await store.openRoot(second); try await gate.waitFor("b.png")
        var drained = false
        let shutdown = Task { await store.shutdown(); drained = true }
        try await waitFor { !store.previews.library.canScan }
        XCTAssertFalse(drained)
        XCTAssertEqual(recorder.active(first), 1)
        await gate.release("b.png")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained, "A superseded request still owns a borrow")
        XCTAssertEqual(recorder.active(first), 1)
        await gate.release("a.png")
        await shutdown.value
        XCTAssertEqual(recorder.liveCount, 0)
        XCTAssertTrue(store.previews.runtime.statuses.isEmpty)
    }

    func testPausedPlayerAndDocumentKeepAccessUntilTheirSessionsClose() async throws {
        QuietWindow.prepareTestProcess()
        let root = try folder(), recorder = ScopeRecorder()
        let fixture = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/landscape.mp4")
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("movie.mp4"))
        try Data("# Scoped document".utf8).write(to: root.appendingPathComponent("notes.md"))
        let scan = try FileScanner.scan(rootURL: root, rootID: UUID())
        let movie = try XCTUnwrap(scan.photos.first { $0.format.isVideo })
        let document = try XCTUnwrap(scan.photos.first { $0.format == .markdown })
        let composition = FrameComposition(libraryFeatures: FrameLibraryFeatures(accessOperations: recorder.operations))
        try await composition.start()
        let access = try XCTUnwrap(composition.library.access)
        try access.activate(root, rootID: movie.rootID)
        composition.preparePlayback(movie)
        try await waitFor { composition.playback.player != nil }
        XCTAssertEqual(composition.playback.player?.rate, 0)
        access.closeRoot()
        XCTAssertEqual(recorder.active(root), 1, "A paused AVPlayer still reads its asset")
        await composition.retireSelection()
        XCTAssertEqual(recorder.active(root), 0)
        try access.activate(root, rootID: document.rootID)
        composition.showDocument(document, path: "notes.md", location: .local(root))
        try await waitFor { composition.documentRenderer.webView.url?.scheme == "frame-document" }
        access.closeRoot()
        XCTAssertEqual(recorder.active(root), 1, "WebKit's source/polling lifetime owns the borrow")
        await composition.retireSelection()
        XCTAssertEqual(recorder.active(root), 0)
        await composition.stop()
        XCTAssertEqual(recorder.starts(root), 2)
    }

    func testPartialAcquisitionFailureAndRepeatedRootReplacementReturnToBaseline() async throws {
        let first = try folder(), second = try folder(), recorder = ScopeRecorder()
        let composition = FrameComposition(libraryFeatures: FrameLibraryFeatures(accessOperations: recorder.operations))
        try await composition.start()
        let access = try XCTUnwrap(composition.library.access)
        let baseline = composition.runtime.resources("access")
        for _ in 0..<20 {
            try access.activate(first, rootID: UUID())
            let lease = try access.acquire([first.appendingPathComponent("image.png"), first])
            access.closeRoot()
            XCTAssertEqual(recorder.active(first), 1)
            lease.release(); lease.release()
            XCTAssertEqual(recorder.active(first), 0)
            XCTAssertEqual(composition.runtime.resources("access"), baseline)
        }
        do { _ = try access.acquire([second, first]); XCTFail("Retired root was reacquired implicitly") } catch {}
        XCTAssertEqual(recorder.liveCount, 0)
        XCTAssertEqual(composition.runtime.resources("access"), baseline, "Partial acquisition must release already borrowed resources")
        try await composition.exclude("access", true)
        do { try access.activate(first, rootID: UUID()); XCTFail("Retained access provider admitted a root") } catch {}
        try await composition.exclude("access", false)
        let next = try XCTUnwrap(composition.library.access)
        XCTAssertFalse(next === access)
        try next.activate(second, rootID: UUID())
        await composition.stop()
        XCTAssertEqual(recorder.liveCount, 0)
    }

    func testUndoReacquiresAnExplicitlySavedRootAfterNavigation() async throws {
        let root = try folder(), trash = try folder(), next = try folder(), recorder = ScopeRecorder()
        let photo = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: UUID()).photos.first)
        let bytes = try Data(contentsOf: photo.url)
        var operations = FrameLocalFileOperations()
        operations.trash = { photos, progress in
            await BatchTrash.move(photos, operation: { source in
                let target = trash.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: source, to: target); return target
            }, progress: progress)
        }
        let composition = FrameComposition(fileFeatures: FrameFileFeatures(operations: operations),
            libraryFeatures: FrameLibraryFeatures(accessOperations: recorder.operations))
        try await composition.start()
        let access = try XCTUnwrap(composition.library.access), feature = try XCTUnwrap(composition.files.trash)
        try access.activate(root, rootID: photo.rootID)
        _ = try await feature.move([photo], root: root, rootID: photo.rootID) { _ in }
        try access.activate(next, rootID: UUID())
        XCTAssertEqual(recorder.active(root), 0)
        let restored = try await feature.restoreLast()
        XCTAssertEqual(restored?.restored.map(\.id), [photo.id])
        XCTAssertEqual(try Data(contentsOf: photo.url), bytes)
        XCTAssertEqual(recorder.starts(root), 2)
        XCTAssertEqual(recorder.active(root), 0)
        XCTAssertEqual(recorder.active(next), 1)
        await composition.stop()
        XCTAssertEqual(recorder.liveCount, 0)
    }

    func testExplicitExportCanChooseAPreviouslyViewedFolder() async throws {
        let destination = try folder(), source = try folder("source.png"), recorder = ScopeRecorder()
        let companion = source.appendingPathComponent("source.json")
        try Data("{\"prompt\":\"export fixture\"}".utf8).write(to: companion)
        let photo = try XCTUnwrap(FileScanner.scan(rootURL: source, rootID: UUID()).photos.first)
        XCTAssertEqual(photo.companions.count, 1)
        let composition = FrameComposition(libraryFeatures: FrameLibraryFeatures(accessOperations: recorder.operations))
        try await composition.start()
        let access = try XCTUnwrap(composition.library.access)
        try access.activate(destination, rootID: UUID())
        try access.activate(source, rootID: photo.rootID)
        let target = destination.appendingPathComponent("copy.png")
        try await XCTUnwrap(composition.files.exporter).copy(photo, root: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: photo.url))
        XCTAssertEqual(recorder.starts(destination), 2, "Explicit export reacquires the containing bookmarked folder")
        XCTAssertEqual(recorder.active(destination), 0)
        XCTAssertEqual(recorder.active(source), 1)
        let exporter = try XCTUnwrap(composition.files.exporter)
        let plan = try await exporter.plan(photo, root: source, folder: destination)
        XCTAssertTrue(plan.replacementNames.isEmpty)
        XCTAssertEqual(recorder.starts(destination), 3)
        XCTAssertEqual(recorder.active(destination), 0)
        try await exporter.export(plan, root: source)
        for member in photo.exportMembers {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(member.url.lastPathComponent)), try Data(contentsOf: member.url))
        }
        XCTAssertEqual(recorder.starts(destination), 4)
        XCTAssertEqual(recorder.active(destination), 0)
        XCTAssertEqual(recorder.active(source), 1)
        await composition.stop()
        XCTAssertEqual(recorder.liveCount, 0)
    }

    func testExportPlanningWithdrawalJoinsWorkerAndReleasesDestination() async throws {
        let source = try folder("source.png"), destination = try folder(), gate = accessReadGate(), recorder = ScopeRecorder()
        addTeardownBlock { await gate.releaseAll() }
        let photo = try XCTUnwrap(FileScanner.scan(rootURL: source, rootID: UUID()).photos.first)
        var operations = FrameLocalFileOperations()
        operations.planExport = { photo, folder in
            let plan = try AssetExporter.plan(photo, folder: folder)
            await gate.wait("plan")
            return plan
        }
        let composition = FrameComposition(fileFeatures: FrameFileFeatures(operations: operations),
            libraryFeatures: FrameLibraryFeatures(accessOperations: recorder.operations))
        try await composition.start()
        try XCTUnwrap(composition.library.access).activate(source, rootID: photo.rootID)
        let exporter = try XCTUnwrap(composition.files.exporter)
        let planning = Task { try await exporter.plan(photo, root: source, folder: destination) }
        try await gate.waitFor("plan")
        XCTAssertEqual(recorder.active(destination), 1)
        var drained = false
        let disable = Task {
            try await composition.exclude("files.export", true)
            drained = true
        }
        try await waitFor { !exporter.isActive }
        XCTAssertFalse(drained)
        XCTAssertEqual(recorder.active(destination), 1)
        await gate.releaseAll()
        do { _ = try await planning.value; XCTFail("Retired export returned a plan to the UI") } catch {}
        try await disable.value
        XCTAssertEqual(recorder.active(destination), 0)
        XCTAssertEqual(recorder.active(source), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(photo.name).path))
        await composition.stop()
        XCTAssertEqual(recorder.liveCount, 0)
    }

    func testExportRetainsTheSelectedDestinationURLAcrossPlanningAndConfirmation() async throws {
        let source = try folder("source.png"), destination = try folder(), parent = try folder()
        let selected = parent.appendingPathComponent("Selected Folder")
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: destination)
        let photo = try XCTUnwrap(FileScanner.scan(rootURL: source, rootID: UUID()).photos.first)
        var started: [URL] = [], stopped: [URL] = []
        let scopes = FrameSecurityScopeOperations(start: { started.append($0); return true }, stop: { stopped.append($0) })
        let composition = FrameComposition(libraryFeatures: FrameLibraryFeatures(accessOperations: scopes))
        try await composition.start()
        try XCTUnwrap(composition.library.access).activate(source, rootID: photo.rootID)
        let exporter = try XCTUnwrap(composition.files.exporter)
        let plan = try await exporter.plan(photo, root: source, folder: selected)
        try await exporter.export(plan, root: source)
        XCTAssertEqual(started.filter { $0 == selected }.count, 2)
        XCTAssertEqual(stopped.filter { $0 == selected }.count, 2)
        XCTAssertFalse(started.contains(destination), "Scope acquisition must use the chosen URL, not the normalized filesystem path")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(photo.name)), try Data(contentsOf: photo.url))
        await composition.stop()
        XCTAssertEqual(started.sorted { $0.path < $1.path }, stopped.sorted { $0.path < $1.path })
    }

    func testResolvedRemoteMediaIsUsableInsideAPreviouslyViewedLocalFolder() async throws {
        let root = try folder(), recorder = ScopeRecorder()
        try FileManager.default.copyItem(at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/landscape.mp4"),
            to: root.appendingPathComponent("cached.mp4"))
        let local = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: UUID()).photos.first { $0.format.isVideo })
        var remote = local
        remote.remote = RemoteAssetReference(source: BridgeSource(id: String(repeating: "a", count: 64), name: "Cache fixture"),
            listingID: UUID(), entry: BridgeEntry(name: "movie.mp4", path: "/videos/movie.mp4", directory: false, size: local.fileSize, modified: "1"))
        let composition = FrameComposition(libraryFeatures: FrameLibraryFeatures(accessOperations: recorder.operations))
        try await composition.start()
        let access = try XCTUnwrap(composition.library.access)
        try access.activate(root, rootID: UUID())
        access.closeRoot()
        let image = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: local.rootID).photos.first { $0.format.isImage })
        let session = try await composition.image(image, pixels: 128)
        XCTAssertNotNil(session.content.image)
        await session.close()
        XCTAssertNotNil(composition.active("playback.video"))
        let playback = try XCTUnwrap(composition.runtime.service(FrameServices.Playback.self))
        try playback.prepare(remote, downloadOriginal: true, resolve: { _ in local })
        try await waitFor { composition.playback.player != nil || composition.playback.failure != nil }
        XCTAssertNotNil(composition.playback.player, "A previously viewed local ancestor must not revoke a newly authorized remote cache file")
        XCTAssertNil(composition.playback.failure)
        await composition.stop()
        XCTAssertEqual(recorder.liveCount, 0)
    }
}

@MainActor
private final class ScopeRecorder {
    private var started: [String: Int] = [:]
    private var stopped: [String: Int] = [:]
    private func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    var operations: FrameSecurityScopeOperations {
        FrameSecurityScopeOperations(start: { self.started[self.key($0), default: 0] += 1; return true }, stop: {
            let key = self.key($0)
            self.stopped[key, default: 0] += 1
            XCTAssertLessThanOrEqual(self.stopped[key, default: 0], self.started[key, default: 0])
        })
    }
    func starts(_ url: URL) -> Int { started[key(url), default: 0] }
    func active(_ url: URL) -> Int { started[key(url), default: 0] - stopped[key(url), default: 0] }
    var liveCount: Int { started.values.reduce(0, +) - stopped.values.reduce(0, +) }
}

private func accessReadGate() -> KeyedGate { KeyedGate(failure: "Metadata read did not start", timeout: CancellationError()) }
