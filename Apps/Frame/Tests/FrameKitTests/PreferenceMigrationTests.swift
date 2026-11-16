import Composition
import SwiftData
import XCTest
@testable import FrameKit

/// The preference document is created once from the legacy UserDefaults values and owns them afterwards.
@MainActor
final class PreferenceMigrationTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, URL) {
        let name = "FramePreferences.\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        return (root, defaults, root.appendingPathComponent("preferences.json"))
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testImportPreservesEveryLayoutAndDomainRecordWithoutCopyingBookmarks() async throws {
        let (_, defaults, storage) = try fixture(), model = try container()
        let roots = (0..<12).map { _ in UUID() }, remote = UUID()
        for id in roots {
            model.mainContext.insert(LibraryRootRecord(id: id, displayName: "Old folder", bookmarkData: Data("private bookmark".utf8)))
        }
        model.mainContext.insert(FavoriteRecord(rootID: roots[0], relativePath: "private.jpg", isFavorite: true))
        try model.mainContext.save()
        defaults.set([roots[11].uuidString], forKey: "hiddenRecentRoots")
        defaults.set(false, forKey: "showsMediaInfo")
        defaults.set(false, forKey: "showsRemoteFolders")
        defaults.set(false, forKey: "localIncludesSubfolders")
        defaults.set(999.0, forKey: "contactSheetThumbnailWidth")
        defaults.set(FrameViewMode.inspect.rawValue, forKey: "layout.\(roots[0])")
        defaults.set(FrameViewMode.contactSheet.rawValue, forKey: "layout.\(remote)")
        let composition = FrameComposition(preferencesURL: storage)
        let store = LibraryStore(defaults: defaults, previews: composition)
        XCTAssertFalse(store.showsRemoteFolders, "Legacy values are visible before the document exists")
        try await composition.bindLibrary(model.mainContext)
        let value = composition.preferences.value
        XCTAssertEqual(value.thumbnailWidth, 360)
        XCTAssertFalse(store.showsMediaInfo)
        XCTAssertFalse(store.showsRemoteFolders)
        XCTAssertFalse(store.localIncludesSubfolders)
        XCTAssertEqual(value.layout(for: roots[0]), .inspect)
        for id in roots.dropFirst() { XCTAssertEqual(value.layout(for: id), .contactSheet) }
        XCTAssertEqual(value.layout(for: remote), .contactSheet)
        XCTAssertEqual(try model.mainContext.fetch(FetchDescriptor<LibraryRootRecord>()).count, 12)
        XCTAssertEqual(try model.mainContext.fetch(FetchDescriptor<FavoriteRecord>()).count, 1)
        let encoded = try String(contentsOf: storage, encoding: .utf8)
        for absent in ["private bookmark", "private.jpg", "hiddenRecentRoots", "library.catalog", "relay.link", "thumbnails"] {
            XCTAssertFalse(encoded.contains(absent), absent)
        }
        XCTAssertFalse(defaults.bool(forKey: "documentLayoutMigrated"))
        await store.shutdown()

        defaults.set(true, forKey: "showsRemoteFolders")
        defaults.set(120.0, forKey: "contactSheetThumbnailWidth")
        let added = UUID()
        model.mainContext.insert(LibraryRootRecord(id: added, displayName: "Later folder", bookmarkData: Data()))
        try model.mainContext.save()
        let reopened = FrameComposition(preferencesURL: storage)
        let reopenedStore = LibraryStore(defaults: defaults, previews: reopened)
        try await reopened.bindLibrary(model.mainContext)
        XCTAssertEqual(reopened.preferences.value, value)
        XCTAssertEqual(reopened.preferences.value.layout(for: added), .inspect, "The one-time layout import must not run again")
        await reopenedStore.shutdown()
    }

    func testFailedFirstSaveStartsNothingAndCanRetryWithoutLosingLegacyPreferences() async throws {
        let (root, defaults, storage) = try fixture()
        defaults.set(false, forKey: "showsRemoteFolders")
        defaults.set(250.0, forKey: "contactSheetThumbnailWidth")
        let composition = FrameComposition(preferencesURL: storage)
        let store = LibraryStore(defaults: defaults, previews: composition)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        do { try await composition.start(); XCTFail("The first save should fail") } catch {}
        XCTAssertTrue(composition.runtime.statuses.isEmpty, "Nothing loads from preferences that were not saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        XCTAssertEqual(defaults.double(forKey: "contactSheetThumbnailWidth"), 250)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try await composition.start()
        XCTAssertFalse(store.showsRemoteFolders)
        XCTAssertEqual(store.thumbnailWidth, 250)
        XCTAssertEqual(composition.link.state, .hidden)
        XCTAssertNil(composition.runtime.status("relay.link"), "Hidden remote folders do not load the link")
        await store.shutdown()
    }

    func testNewerDocumentIsNeverAppliedOrOverwritten() async throws {
        let (_, _, storage) = try fixture()
        let future = Data(#"{"version":99,"preferences":{"appearance":"new"}}"#.utf8)
        try future.write(to: storage)
        let composition = FrameComposition(preferencesURL: storage)
        do { try await composition.start(); XCTFail("A newer document was accepted") } catch {}
        XCTAssertTrue(composition.runtime.statuses.isEmpty)
        XCTAssertEqual(try Data(contentsOf: storage), future)
        await composition.stop()
    }

    func testDocumentWithoutPluginsLoadsDefaultsAndAChangedChoiceSurvivesReload() async throws {
        let (_, _, storage) = try fixture()
        let plugin = FramePlugins.promptSearch
        let first = FrameComposition(preferencesURL: storage)
        try await first.start()
        try await first.updatePreferences { $0.showsMediaInfo = false }
        await first.stop()
        // Rewrite the saved document as it was before plugins existed.
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as? [String: Any])
        var document = try XCTUnwrap(envelope["preferences"] as? [String: Any])
        XCTAssertNotNil(document.removeValue(forKey: "plugins"))
        envelope["preferences"] = document
        try JSONSerialization.data(withJSONObject: envelope).write(to: storage)
        let old = FrameComposition(preferencesURL: storage)
        try await old.start()
        XCTAssertEqual(old.preferences.store.value.plugins, PluginChoices())
        XCTAssertFalse(old.preferences.value.showsMediaInfo, "Every other key still loads")
        XCTAssertTrue(old.isPluginEnabled(plugin))
        XCTAssertNotNil(old.active("prompt-search"))
        try await old.setPlugin(plugin, enabled: false)
        XCTAssertNil(old.runtime.status("prompt-search"))
        await old.stop()
        let encoded = try String(contentsOf: storage, encoding: .utf8)
        XCTAssertTrue(encoded.contains(#""prompt-search" : false"#))
        let reopened = FrameComposition(preferencesURL: storage)
        try await reopened.start()
        XCTAssertFalse(reopened.isPluginEnabled(plugin))
        XCTAssertNil(reopened.runtime.status("prompt-search"))
        XCTAssertNil(reopened.runtime.status("remote/prompt-search"))
        XCTAssertFalse(reopened.preferences.value.showsMediaInfo)
        await reopened.stop()
    }

    func testLayoutImportWaitsForCatalogAndPendingNavigationSavesTheCorrectRoot() async throws {
        let (root, defaults, storage) = try fixture(), model = try container()
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data().write(to: url.appendingPathComponent("image.jpg"))
        }
        let composition = FrameComposition(preferencesURL: storage)
        let store = LibraryStore(defaults: defaults, previews: composition)
        try await composition.start()
        XCTAssertFalse(composition.preferences.store.value.importedDocumentLayouts)
        await store.start(modelContext: model.mainContext)
        XCTAssertTrue(composition.preferences.store.value.importedDocumentLayouts)
        await store.openRoot(first)
        let firstID = try XCTUnwrap(store.activeRootID)
        let scanner = composition.active("library.scanning")?.generation
        let media = composition.active("thumbnails")?.generation
        store.setViewMode(.contactSheet)
        await store.openRoot(second)
        let secondID = try XCTUnwrap(store.activeRootID)
        XCTAssertNotEqual(firstID, secondID, "A queued refresh must not supersede navigation")
        store.setViewMode(.contactSheet)
        store.setViewMode(.inspect)
        store.toggleInfo(); store.toggleInfo()
        await store.setIncludesSubfolders(false)
        await store.settlePreferences()
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.showsMediaInfo)
        XCTAssertEqual(composition.preferences.value.layout(for: firstID), .contactSheet)
        XCTAssertEqual(composition.preferences.value.layout(for: secondID), .inspect)
        XCTAssertNotNil(scanner)
        XCTAssertEqual(composition.active("library.scanning")?.generation, scanner, "Display preferences never reload a feature")
        XCTAssertEqual(composition.active("thumbnails")?.generation, media)
        await store.openRecent(firstID)
        XCTAssertEqual(store.viewMode, .contactSheet)
        store.setViewMode(.inspect)
        await store.shutdown() // Accepted navigation preferences drain before composition shutdown.
        let reopened = FrameComposition(preferencesURL: storage)
        try await reopened.start()
        XCTAssertEqual(reopened.preferences.value.layout(for: firstID), .inspect)
        XCTAssertFalse(reopened.preferences.value.localIncludesSubfolders)
        await reopened.stop()
    }
}
