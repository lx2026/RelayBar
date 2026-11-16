import Composition
import SwiftData
import XCTest
@testable import FrameKit

@MainActor
final class LibraryFeatureTests: XCTestCase {
    private func folder(_ name: String = "a.jpg") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("asset".utf8).write(to: root.appendingPathComponent(name))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func defaults() -> UserDefaults {
        let suite = "FrameLibrary.\(UUID())", value = UserDefaults(suiteName: suite)!
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }
    private func container() throws -> ModelContainer {
        try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Library did not reach its synchronization point")
        throw CompositionError("Fixture timeout")
    }

    func testBindingCatalogIsTransientAndDoesNotWriteDomainDataIntoSettings() async throws {
        let root = try folder(), storage = root.appendingPathComponent("preferences.json")
        let composition = FrameComposition(preferencesURL: storage)
        let store = LibraryStore(defaults: defaults(), previews: composition)
        try await composition.start()
        XCTAssertFalse(composition.library.canUseCatalog)
        XCTAssertFalse(composition.library.canFavorite)
        XCTAssertTrue(composition.files.canExport)
        let model = try container()
        await store.start(modelContext: model.mainContext)
        XCTAssertTrue(composition.library.canUseCatalog)
        XCTAssertTrue(composition.library.canScan)
        XCTAssertTrue(composition.library.canFavorite)
        XCTAssertTrue(composition.preferences.store.value.importedDocumentLayouts)
        let bytes = try Data(contentsOf: storage)
        await store.openRoot(root)
        store.toggleFavorite()
        XCTAssertEqual(try Data(contentsOf: storage), bytes)
        XCTAssertEqual(try model.mainContext.fetch(FetchDescriptor<LibraryRootRecord>()).count, 1)
        XCTAssertEqual(try model.mainContext.fetch(FetchDescriptor<FavoriteRecord>()).count, 1)
        await store.shutdown()
    }

    func testFavoriteWithdrawalPreservesRecordsAndDoesNotRestartCatalogOrScanner() async throws {
        let root = try folder(), model = try container(), defaults = defaults()
        let store = LibraryStore(defaults: defaults)
        await store.start(modelContext: model.mainContext)
        await store.openRoot(root)
        let photo = try XCTUnwrap(store.selectedPhoto), feature = try XCTUnwrap(store.previews.library.favorites)
        store.toggleFavorite()
        XCTAssertTrue(store.isFavorite(photo))
        let catalog = store.previews.active("library.catalog")?.generation
        let scanner = store.previews.active("library.scanning")?.generation
        try await store.previews.exclude("library.favorites", true)
        XCTAssertFalse(store.canFavorite)
        store.toggleFavorite()
        do { try feature.set([photo], favorite: false); XCTFail("Retired favorite service wrote the catalog") } catch {}
        let saved = try model.mainContext.fetch(FetchDescriptor<FavoriteRecord>())
        XCTAssertEqual(saved.count, 1); XCTAssertTrue(saved[0].isFavorite)
        XCTAssertEqual(store.previews.active("library.catalog")?.generation, catalog)
        XCTAssertEqual(store.previews.active("library.scanning")?.generation, scanner)
        try await store.previews.exclude("library.favorites", false)
        XCTAssertTrue(store.canFavorite)
        XCTAssertTrue(store.isFavorite(photo))
        store.toggleFavorite()
        XCTAssertFalse(saved[0].isFavorite)
        store.removeRecent(photo.rootID)
        XCTAssertTrue(store.recentFolders.isEmpty)
        XCTAssertEqual(try model.mainContext.fetch(FetchDescriptor<LibraryRootRecord>()).count, 1)
        await store.shutdown()
    }

    func testScannerWithdrawalRejectsWarmReadsAndReenableRestoresWatching() async throws {
        let root = try folder(), model = try container(), store = LibraryStore(defaults: defaults())
        await store.start(modelContext: model.mainContext)
        await store.openRoot(root)
        let old = try XCTUnwrap(store.localFolders), favorite = store.previews.active("library.favorites")?.generation
        XCTAssertFalse(old.results.isEmpty)
        try await store.previews.exclude("library.scanning", true)
        XCTAssertTrue(old.isStopped)
        XCTAssertFalse(store.canRefresh)
        XCTAssertTrue(store.canFavorite)
        do { _ = try await old.load(""); XCTFail("Stopped index returned a warm read") } catch {}
        try await store.previews.exclude("library.scanning", false)
        let current = try XCTUnwrap(store.localFolders)
        XCTAssertFalse(current === old)
        try await waitFor { current.results[""] != nil }
        try Data("new asset".utf8).write(to: root.appendingPathComponent("b.jpg"))
        try await waitFor { store.photos.contains { $0.name == "b.jpg" } }
        XCTAssertEqual(store.previews.active("library.favorites")?.generation, favorite)
        await store.shutdown()
        XCTAssertTrue(current.isStopped)
    }

    func testShutdownWaitsForSupersededScanWithoutReplacingCurrentRoot() async throws {
        let first = try folder("a.jpg"), second = try folder("b.jpg"), model = try container(), gate = LibraryScanGate()
        addTeardownBlock { await gate.releaseAll() }
        let store = LibraryStore(defaults: defaults(), scanner: { root, id in
            let result = try FileScanner.scan(rootURL: root, rootID: id)
            await gate.wait(root.path)
            return result // Deliberately ignore cancellation after the filesystem read.
        })
        addTeardownBlock { await gate.releaseAll(); await store.shutdown(); _ = model }
        await store.start(modelContext: model.mainContext)
        await store.openRoot(first)
        store.setViewMode(.contactSheet)
        try await gate.waitFor(first.path)
        await store.openRoot(second)
        store.setViewMode(.contactSheet)
        try await gate.waitFor(second.path)
        var closed = false
        let shutdown = Task { await store.shutdown(); closed = true }
        await gate.release(second.path)
        try await waitFor { !store.previews.library.canScan }
        XCTAssertFalse(closed, "The first, superseded scan must still be owned")
        await gate.release(first.path)
        await shutdown.value
        XCTAssertEqual(store.rootURL?.path, second.path)
        XCTAssertTrue(store.photos.allSatisfy { $0.name == "b.jpg" })
        XCTAssertTrue(store.previews.runtime.statuses.isEmpty)
    }

    func testCatalogWithdrawalPreservesBookmarksAndScannerRequiresMatchingRoot() async throws {
        let first = try folder(), second = try folder(), model = try container(), store = LibraryStore(defaults: defaults())
        await store.start(modelContext: model.mainContext)
        await store.openRoot(first)
        let rootID = try XCTUnwrap(store.activeRootID), catalog = try XCTUnwrap(store.previews.library.catalog)
        let scanning = try XCTUnwrap(store.previews.library.scanning)
        let records = try model.mainContext.fetch(FetchDescriptor<LibraryRootRecord>())
        let bookmark = try XCTUnwrap(records.first?.bookmarkData)
        do { _ = try await scanning.scan(root: second, rootID: rootID); XCTFail("Scanner accepted another root's identity") } catch {}
        try await store.previews.exclude("library.catalog", true)
        XCTAssertFalse(store.canOpenLocalFolder)
        XCTAssertFalse(store.previews.library.canScan)
        XCTAssertTrue(store.previews.library.canFavorite)
        do { _ = try catalog.open(second); XCTFail("Retired catalog created a bookmark") } catch {}
        XCTAssertEqual(try model.mainContext.fetch(FetchDescriptor<LibraryRootRecord>()).count, 1)
        XCTAssertEqual(records[0].bookmarkData, bookmark)
        try await store.previews.exclude("library.catalog", false)
        XCTAssertTrue(store.canOpenLocalFolder)
        XCTAssertEqual(store.recentFolders.first?.id, rootID)
        await store.openRoot(second, replacingRootID: rootID)
        XCTAssertEqual(store.activeRootID, rootID)
        XCTAssertEqual(store.rootURL?.path, second.path)
        await store.shutdown()
    }
}

private actor LibraryScanGate {
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []
    private var closed = false
    func wait(_ path: String) async {
        if !closed, !released.contains(path) { await withCheckedContinuation { pending[path] = $0 } }
    }
    func waitFor(_ path: String) async throws {
        for _ in 0..<500 {
            if pending[path] != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scan did not start"); throw CompositionError("Fixture timeout")
    }
    func release(_ path: String) { released.insert(path); pending.removeValue(forKey: path)?.resume() }
    func releaseAll() {
        closed = true
        for continuation in pending.values { continuation.resume() }
        pending.removeAll()
    }
}
