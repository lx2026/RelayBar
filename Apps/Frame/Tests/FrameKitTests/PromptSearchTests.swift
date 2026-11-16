import BridgeProtocol
import Composition
import XCTest
@testable import FrameKit

@MainActor
final class PromptSearchTests: XCTestCase {
    private let source = BridgeSource(id: String(repeating: "c", count: 64), name: "Search fixture")

    private func defaults() -> UserDefaults {
        let suite = "FramePromptSearch.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search did not reach the expected state")
        throw BridgeError("Fixture timeout")
    }

    /// A remote asset in `/photos` with one JSON companion of the given size and listing modification time.
    private func remotePhoto(_ name: String, companionSize: Int64 = 20, companionModified: String = "1") -> PhotoItem {
        let path = "/photos/" + name
        let companionName = (name as NSString).deletingPathExtension + ".json"
        let companionPath = "/photos/" + companionName
        let companion = AssetFile(url: URL(fileURLWithPath: "/fixture" + companionPath), relativePath: companionPath,
                                  size: companionSize, modifiedAt: nil, identifier: nil)
        var photo = PhotoItem(id: path, rootID: UUID(), url: URL(fileURLWithPath: "/fixture" + path), relativePath: path,
                              folderRelativePath: "/photos", name: name, format: .jpeg, fileSize: 10, createdAt: nil,
                              modifiedAt: nil, fileIdentifier: nil, companions: [companion])
        photo.remote = RemoteAssetReference(source: source, listingID: UUID(),
                                            entry: BridgeEntry(name: name, path: path, directory: false, size: 10, modified: "1"),
                                            companions: [BridgeEntry(name: companionName, path: companionPath, directory: false,
                                                                     size: companionSize, modified: companionModified)])
        return photo
    }

    /// A store showing a remote folder that lists `photos`, answers companion text through `files` and
    /// performs file actions through `actions`.
    private func remoteStore(_ photos: [PhotoItem], files: SearchFiles,
                             actions: (any RemoteActionServing)? = nil) async -> (LibraryStore, FixedRemoteSession) {
        let library = FixtureRemoteLibrary(loader: { _, path in
            ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: path, relativePath: path, photoCount: photos.count, children: []))
        })
        let session = FixedRemoteSession(PartialRemoteSession(library: library, files: files, actions: actions))
        let store = LibraryStore(defaults: defaults(), previews: FrameComposition(remoteSession: session))
        await store.openRemote(source, path: "/photos")
        XCTAssertEqual(store.photos.count, photos.count)
        return (store, session)
    }

    /// Every feature's generation except the plugin's own.
    private func generations(_ composition: FrameComposition, excluding plugin: PluginDescriptor) -> [String: UInt64] {
        let others = composition.runtime.statuses.filter { !plugin.features.contains($0.id) }
        return Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0.generation) })
    }

    func testEveryWordMustAppearIgnoringCaseAndDiacritics() {
        let text = "Golden harbor at dusk, \"café\" lights"
        XCTAssertTrue(FramePromptSearchFeature.matches(text, query: "harbor"))
        XCTAssertTrue(FramePromptSearchFeature.matches(text, query: "dusk golden"))
        XCTAssertFalse(FramePromptSearchFeature.matches(text, query: "golden moon"))
        XCTAssertTrue(FramePromptSearchFeature.matches(text, query: "\"café\""), "A quote is an ordinary character")
        XCTAssertFalse(FramePromptSearchFeature.matches(text, query: "\"golden harbor\""), "Quotes do not make a phrase")
        XCTAssertTrue(FramePromptSearchFeature.matches(text, query: ""))
        XCTAssertTrue(FramePromptSearchFeature.matches(text, query: "  "))
        XCTAssertTrue(FramePromptSearchFeature.matches(text, query: "CAFE"))
        XCTAssertTrue(FramePromptSearchFeature.matches("Crème brûlée", query: "creme BRULEE"))
        XCTAssertTrue(FramePromptSearchFeature.matches(text, query: "gOLDEN"))
    }

    func testLocalFolderReturnsExactlyTheAssetsWhoseNameOrCompanionTextMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FramePromptSearch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("harbor.jpg"))
        try Data(#"{"prompt": "golden harbor at dusk"}"#.utf8).write(to: root.appendingPathComponent("harbor.json"))
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("terrace.jpg"))
        try Data("Café terrace on a rainy evening".utf8).write(to: root.appendingPathComponent("terrace.txt"))
        try pngData(text: "golden retriever on a beach").write(to: root.appendingPathComponent("retriever.png"))
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("plain.jpg"))
        let photos = try FileScanner.scan(rootURL: root, rootID: UUID()).photos
        XCTAssertEqual(photos.count, 4)
        func ids(_ names: String...) -> Set<PhotoItem.ID> {
            Set(photos.filter { names.contains($0.name) }.map(\.id))
        }
        let composition = FrameComposition()
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self))
        var found = try await feature.matches(in: photos, query: "golden")
        XCTAssertEqual(found, ids("harbor.jpg", "retriever.png"))
        found = try await feature.matches(in: photos, query: "golden HARBOR")
        XCTAssertEqual(found, ids("harbor.jpg"))
        found = try await feature.matches(in: photos, query: "cafe evening")
        XCTAssertEqual(found, ids("terrace.jpg"))
        found = try await feature.matches(in: photos, query: "plain")
        XCTAssertEqual(found, ids("plain.jpg"), "The file name is searched too")
        found = try await feature.matches(in: photos, query: "zebra")
        XCTAssertEqual(found, [])
        await composition.stop()
    }

    func testRemoteRealmAnswersAndWithdrawingTheSessionStopsAPendingSearch() async throws {
        let gate = searchGate()
        addTeardownBlock { await gate.releaseAll() }
        let photos = [remotePhoto("harbor.jpg"), remotePhoto("terrace.jpg"), remotePhoto("late.jpg")]
        let texts = [photos[0].id: "golden harbor", photos[1].id: "rainy terrace", photos[2].id: "golden hour"]
        let files = SearchFiles(texts: texts, calls: SearchCalls(), hold: { photo, call in
            guard photo.name == "late.jpg" else { return }
            await gate.wait("late#\(call)")
        })
        let (store, session) = await remoteStore(photos, files: files)
        let runtime = store.previews.runtime
        XCTAssertTrue(store.isSearchAvailable)
        let feature = try XCTUnwrap(runtime.service(FrameServices.PromptSearch.self, realm: "remote"))
        XCTAssertFalse(feature === runtime.service(FrameServices.PromptSearch.self), "Each world has its own instance")
        let found = try await feature.matches(in: Array(photos.prefix(2)), query: "golden")
        XCTAssertEqual(found, [photos[0].id])
        store.setSearchQuery("golden")
        try await gate.waitFor("late#1")
        let pending = Task { try await feature.matches(in: photos, query: "golden") }
        try await gate.waitFor("late#2")
        // Withdrawal is synchronous: the query, the filter and the store's search are gone before any cleanup runs.
        session.withdraw()
        XCTAssertFalse(feature.isActive)
        XCTAssertFalse(store.isSearchAvailable)
        XCTAssertEqual(store.searchQuery, "")
        XCTAssertNil(store.searchMatchCount)
        XCTAssertNil(store.searchTask)
        XCTAssertEqual(store.visiblePhotos.count, photos.count)
        await gate.releaseAll()
        do {
            _ = try await pending.value
            XCTFail("A search answered after its session was withdrawn")
        } catch {}
        session.restore()
        await runtime.settled()
        XCTAssertTrue(store.isSearchAvailable)
        await store.shutdown()
    }

    func testSupersededSearchNeverOverwritesTheNewerResult() async throws {
        let gate = searchGate()
        addTeardownBlock { await gate.releaseAll() }
        let photos = [remotePhoto("one.jpg"), remotePhoto("two.jpg"), remotePhoto("three.jpg")]
        let texts = [photos[0].id: "alpha", photos[1].id: "bravo", photos[2].id: "alpha bravo"]
        let files = SearchFiles(texts: texts, calls: SearchCalls(), hold: { photo, call in
            guard photo.name == "one.jpg", call == 1 else { return }
            await gate.wait()
        })
        let (store, _) = await remoteStore(photos, files: files)
        store.setSearchQuery("alpha")
        let older = try XCTUnwrap(store.searchTask)
        try await gate.waitFor()
        store.setSearchQuery("bravo")
        XCTAssertNil(store.searchMatchCount, "Before the first result the list is not filtered")
        XCTAssertEqual(store.visiblePhotos.count, photos.count)
        let newer = try XCTUnwrap(store.searchTask)
        await newer.value
        XCTAssertEqual(Set(store.visiblePhotos.map(\.id)), [photos[1].id, photos[2].id])
        XCTAssertEqual(store.searchMatchCount, 2)
        await gate.release()
        await older.value
        XCTAssertEqual(store.searchQuery, "bravo")
        XCTAssertEqual(Set(store.visiblePhotos.map(\.id)), [photos[1].id, photos[2].id], "The older result replaced the newer one")
        store.setSearchQuery("alpha bravo")
        XCTAssertEqual(store.searchMatchCount, 2, "The previous result stays until the new one arrives")
        await store.searchTask?.value
        XCTAssertEqual(store.visiblePhotos.map(\.id), [photos[2].id])
        await store.shutdown()
    }

    func testCachedTextIsReusedUntilACompanionSizeChanges() async throws {
        let photos = [remotePhoto("one.jpg"), remotePhoto("two.jpg")]
        let calls = SearchCalls()
        let files = SearchFiles(texts: [photos[0].id: "alpha", photos[1].id: "bravo"], calls: calls)
        let composition = FrameComposition.fixture(files: files)
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self, realm: "remote"))
        var found = try await feature.matches(in: photos, query: "alpha")
        XCTAssertEqual(found, [photos[0].id])
        var reads = await calls.ids
        XCTAssertEqual(reads.count, 2)
        found = try await feature.matches(in: photos, query: "bravo")
        XCTAssertEqual(found, [photos[1].id])
        reads = await calls.ids
        XCTAssertEqual(reads.count, 2, "The second search reads nothing")
        let edited = remotePhoto("one.jpg", companionSize: 21)
        found = try await feature.matches(in: [edited, photos[1]], query: "alpha")
        XCTAssertEqual(found, [edited.id])
        reads = await calls.ids
        XCTAssertEqual(reads.count, 3, "Only the asset whose companion changed is read again")
        XCTAssertEqual(reads.last, edited.id)
        await composition.stop()
    }

    func testSwitchingThePluginOffRemovesTheSearchAndSwitchingItOnRestoresIt() async throws {
        let photos = [remotePhoto("one.jpg"), remotePhoto("two.jpg"), remotePhoto("three.jpg")]
        let texts = [photos[0].id: "alpha", photos[1].id: "bravo", photos[2].id: "alpha"]
        let (store, _) = await remoteStore(photos, files: SearchFiles(texts: texts, calls: SearchCalls()))
        let composition = store.previews
        let plugin = FramePlugins.promptSearch
        XCTAssertTrue(composition.isPluginEnabled(plugin))
        store.setSearchQuery("alpha")
        await store.searchTask?.value
        XCTAssertEqual(store.searchMatchCount, 2)
        let others = generations(composition, excluding: plugin)
        try await composition.setPlugin(plugin, enabled: false)
        XCTAssertFalse(composition.isPluginEnabled(plugin))
        XCTAssertFalse(store.isSearchAvailable)
        XCTAssertEqual(store.searchQuery, "")
        XCTAssertNil(store.searchMatchCount)
        XCTAssertEqual(store.visiblePhotos.count, photos.count)
        for id in plugin.features {
            XCTAssertNil(composition.runtime.status(id))
        }
        XCTAssertEqual(generations(composition, excluding: plugin), others)
        store.setSearchQuery("bravo")
        XCTAssertEqual(store.searchQuery, "", "Without the plugin there is nothing to search with")
        try await composition.setPlugin(plugin, enabled: true)
        XCTAssertTrue(store.isSearchAvailable)
        for id in plugin.features {
            XCTAssertNotNil(composition.active(id))
        }
        XCTAssertEqual(generations(composition, excluding: plugin), others)
        await store.shutdown()
    }

    func testSelectionNeverStaysOutsideTheSearchResult() async throws {
        let photos = [remotePhoto("one.jpg"), remotePhoto("two.jpg"), remotePhoto("three.jpg")]
        let texts = [photos[0].id: "alpha", photos[1].id: "bravo", photos[2].id: "alpha"]
        let (store, _) = await remoteStore(photos, files: SearchFiles(texts: texts, calls: SearchCalls()))
        let hidden = try XCTUnwrap(store.photos.first { $0.id == photos[1].id })
        store.select(hidden)
        XCTAssertEqual(store.selectedPhoto?.id, hidden.id)
        store.setSearchQuery("alpha")
        await store.searchTask?.value
        XCTAssertNotEqual(store.selectedPhoto?.id, hidden.id)
        assertSelectionIsVisible(store)
        store.setSearchQuery("")
        assertSelectionIsVisible(store)
        store.setViewMode(.contactSheet)
        store.updateGridSelection(Set(photos.map(\.id)), currentID: hidden.id)
        XCTAssertEqual(store.actionPhotos.count, photos.count)
        store.setSearchQuery("alpha")
        await store.searchTask?.value
        XCTAssertEqual(Set(store.actionPhotos.map(\.id)), [photos[0].id, photos[2].id])
        assertSelectionIsVisible(store)
        store.setSearchQuery("")
        assertSelectionIsVisible(store)
        await store.shutdown()
    }

    func testLocalSearchReadsTheWholeCompanionAndNeverTheSentenceForABinaryOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FramePromptSearchWhole-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        // The metadata panel shows the first 24,000 characters of a companion; search reads all of it.
        let padding = String(repeating: "node ", count: 12_000)
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("workflow.jpg"))
        try Data((padding + "lighthouse").utf8).write(to: root.appendingPathComponent("workflow.txt"))
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("binary.jpg"))
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: root.appendingPathComponent("binary.txt"))
        let photos = try FileScanner.scan(rootURL: root, rootID: UUID()).photos
        XCTAssertEqual(photos.count, 2)
        let composition = FrameComposition()
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self))
        var found = try await feature.matches(in: photos, query: "lighthouse")
        XCTAssertEqual(found, Set(photos.filter { $0.name == "workflow.jpg" }.map(\.id)))
        found = try await feature.matches(in: photos, query: "preview")
        XCTAssertEqual(found, [], "The sentence shown for a binary companion is not searched")
        await composition.stop()
    }

    func testUnreadableCompanionIsLeftOutAndReadAgainUntilItSucceeds() async throws {
        let photos = [remotePhoto("flaky.jpg"), remotePhoto("large.jpg")]
        let calls = SearchCalls()
        let texts = [photos[0].id: "golden harbor", photos[1].id: RelayRemoteClient.oversizedCompanionText]
        let files = SearchFiles(texts: texts, calls: calls, failsFirstRead: [photos[0].id])
        let composition = FrameComposition.fixture(files: files)
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self, realm: "remote"))
        var found = try await feature.matches(in: photos, query: "cannot preview")
        XCTAssertEqual(found, [], "The sentence for an unreadable companion is not searched")
        found = try await feature.matches(in: photos, query: "exceeds")
        XCTAssertEqual(found, [], "The sentence for an oversized companion is not searched")
        found = try await feature.matches(in: photos, query: "golden")
        XCTAssertEqual(found, [photos[0].id])
        let reads = await calls.ids
        XCTAssertEqual(reads.filter { $0 == photos[0].id }.count, 2, "The unreadable asset was not cached and was read again")
        XCTAssertEqual(reads.filter { $0 == photos[1].id }.count, 1, "The oversized asset was cached")
        await composition.stop()
    }

    func testCacheStaysWithinItsBoundAndResultsStayCorrect() async throws {
        let photos = (1...4).map { remotePhoto("p\($0).jpg") }
        let texts = [photos[0].id: "alpha", photos[1].id: "alpha", photos[2].id: "alpha", photos[3].id: "bravo"]
        let calls = SearchCalls()
        let composition = FrameComposition.fixture(files: SearchFiles(texts: texts, calls: calls))
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self, realm: "remote"))
        // Each asset's text is "pN.jpg\nalpha": 12 characters, so two fit and a third empties the cache.
        feature.cacheLimit = 30
        var found = try await feature.matches(in: photos, query: "alpha")
        XCTAssertEqual(found, Set(photos.prefix(3).map(\.id)))
        XCTAssertGreaterThan(feature.cachedCharacters, 0)
        XCTAssertLessThanOrEqual(feature.cachedCharacters, 30)
        found = try await feature.matches(in: photos, query: "bravo")
        XCTAssertEqual(found, [photos[3].id])
        XCTAssertLessThanOrEqual(feature.cachedCharacters, 30)
        found = try await feature.matches(in: photos, query: "alpha")
        XCTAssertEqual(found, Set(photos.prefix(3).map(\.id)))
        XCTAssertLessThanOrEqual(feature.cachedCharacters, 30)
        let reads = await calls.ids
        XCTAssertGreaterThan(reads.count, photos.count, "Text dropped from the full cache is read again")
        // With a bound smaller than any one text nothing is cached, and each read is still matched correctly.
        feature.cacheLimit = 1
        found = try await feature.matches(in: photos.map { remotePhoto($0.name, companionModified: "2") }, query: "bravo")
        XCTAssertEqual(found, [photos[3].id])
        XCTAssertLessThanOrEqual(feature.cachedCharacters, 30)
        await composition.stop()
    }

    func testViewsAreToldAtOnceWhenTheSearchFeatureComesAndGoes() async throws {
        let photos = [remotePhoto("one.jpg")]
        let (store, session) = await remoteStore(photos, files: SearchFiles(texts: [:], calls: SearchCalls()))
        let plugin = FramePlugins.promptSearch
        var available: [Bool] = []
        let observation = store.objectWillChange.sink { _ in available.append(store.isSearchAvailable) }
        try await store.previews.setPlugin(plugin, enabled: false)
        XCTAssertEqual(available.last, false)
        available.removeAll()
        try await store.previews.setPlugin(plugin, enabled: true)
        XCTAssertEqual(available.last, true)
        // Without the remote library no folder index publishes on withdrawal, so the store alone tells its views.
        try await store.previews.exclude("remote/library", true)
        available.removeAll()
        session.withdraw()
        XCTAssertEqual(available, [false], "The views were not told at once that the field is gone")
        observation.cancel()
        await store.previews.runtime.settled()
        await store.shutdown()
    }

    func testNothingTheSearchHidesCanBeActedOn() async throws {
        let photos = [remotePhoto("one.jpg"), remotePhoto("two.jpg"), remotePhoto("three.jpg")]
        let texts = [photos[0].id: "alpha", photos[1].id: "bravo", photos[2].id: "alpha"]
        let deletions = SearchCalls()
        let actions = FixtureRemoteActions(deletion: { targets, _ in
            for target in targets {
                _ = await deletions.record(target.id)
            }
            return []
        })
        let (store, _) = await remoteStore(photos, files: SearchFiles(texts: texts, calls: SearchCalls()), actions: actions)
        let hidden = try XCTUnwrap(store.photos.first { $0.id == photos[1].id })
        store.setSearchQuery("alpha")
        await store.searchTask?.value
        XCTAssertEqual(store.searchMatchCount, 2)
        // Preview layout: a hidden asset shown in the viewer cannot be deleted, archived, exported or favourited.
        store.inspect(hidden)
        XCTAssertEqual(store.selectedPhoto?.id, hidden.id)
        assertActionTargetsAreVisible(store)
        XCTAssertFalse(store.canDelete)
        XCTAssertFalse(store.canArchive)
        XCTAssertFalse(store.canExport)
        XCTAssertFalse(store.canFavorite)
        await store.deleteSelection()
        store.select(hidden)
        assertActionTargetsAreVisible(store)
        store.navigate(by: 1)
        assertSelectionIsVisible(store)
        // Grid: a multiple selection that names a hidden asset acts only on the visible ones.
        store.setViewMode(.contactSheet)
        store.updateGridSelection(Set(photos.map(\.id)), currentID: hidden.id)
        assertSelectionIsVisible(store)
        // Select mode: a hidden asset checked from the viewer is not a target either.
        store.toggleSelectMode()
        store.inspect(hidden)
        store.toggleCurrentSelection()
        let visible = try XCTUnwrap(store.photos.first { $0.id == photos[2].id })
        store.select(visible)
        store.toggleCurrentSelection()
        XCTAssertTrue(store.batchSelection.ids.contains(hidden.id))
        XCTAssertEqual(store.actionPhotos.map(\.id), [visible.id])
        XCTAssertTrue(store.canDelete)
        await store.deleteSelection()
        let deleted = await deletions.ids
        XCTAssertEqual(deleted, [visible.id], "Delete reached an asset the search hides")
        store.toggleSelectMode()
        // Sidebar and links: choosing a hidden asset ends the search, so it is visible again.
        store.selectFile(hidden)
        XCTAssertEqual(store.searchQuery, "")
        XCTAssertNil(store.searchMatchCount)
        XCTAssertEqual(store.selectedPhoto?.id, hidden.id)
        assertSelectionIsVisible(store)
        await store.shutdown()
    }

    func testShowAllFilesAlsoEndsTheSearch() async throws {
        let photos = [remotePhoto("one.jpg"), remotePhoto("two.jpg")]
        let texts = [photos[0].id: "alpha", photos[1].id: "bravo"]
        let (store, _) = await remoteStore(photos, files: SearchFiles(texts: texts, calls: SearchCalls()))
        store.setSearchQuery("zebra")
        await store.searchTask?.value
        XCTAssertEqual(store.searchMatchCount, 0)
        XCTAssertTrue(store.visiblePhotos.isEmpty)
        store.clearFileFilters()
        XCTAssertEqual(store.searchQuery, "")
        XCTAssertNil(store.searchMatchCount)
        XCTAssertEqual(store.visiblePhotos.count, photos.count)
        assertSelectionIsVisible(store)
        await store.shutdown()
    }

    func testCancelledReadIsNeverCached() async throws {
        let gate = searchGate()
        addTeardownBlock { await gate.releaseAll() }
        let photo = remotePhoto("late.jpg")
        let calls = SearchCalls()
        let files = SearchFiles(texts: [photo.id: "golden hour"], calls: calls, hold: { _, call in
            guard call == 1 else { return }
            await gate.wait()
        })
        let composition = FrameComposition.fixture(files: files)
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self, realm: "remote"))
        let cancelled = Task { try await feature.matches(in: [photo], query: "golden") }
        try await gate.waitFor()
        cancelled.cancel()
        await gate.release()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled search returned a result")
        } catch {}
        let found = try await feature.matches(in: [photo], query: "golden")
        XCTAssertEqual(found, [photo.id], "The cancelled read left a file-name-only entry in the cache")
        let reads = await calls.ids
        XCTAssertEqual(reads.count, 2)
        await composition.stop()
    }

    func testUnloadWaitsForASearchInProgressAndDropsItsResult() async throws {
        let gate = searchGate()
        addTeardownBlock { await gate.releaseAll() }
        let photo = remotePhoto("late.jpg")
        let files = SearchFiles(texts: [photo.id: "golden hour"], calls: SearchCalls(), hold: { _, _ in
            await gate.wait()
        })
        let composition = FrameComposition.fixture(files: files)
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self, realm: "remote"))
        let search = Task { try await feature.matches(in: [photo], query: "golden") }
        try await gate.waitFor()
        var unloaded = false
        let disable = Task {
            try await composition.exclude("remote/prompt-search", true)
            unloaded = true
        }
        try await waitFor { !feature.isActive }
        XCTAssertFalse(unloaded, "The feature finished unloading while a search was still running")
        await gate.release()
        do {
            _ = try await search.value
            XCTFail("A withdrawn feature returned a result")
        } catch {}
        try await disable.value
        XCTAssertTrue(unloaded)
        XCTAssertNil(composition.runtime.status("remote/prompt-search"))
        await composition.stop()
    }

    func testAnEditThatKeepsTheSizeIsReadAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FramePromptSearchEdit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let notes = root.appendingPathComponent("note.txt")
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("note.jpg"))
        try Data("alpha".utf8).write(to: notes)
        let rootID = UUID()
        let composition = FrameComposition()
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self))
        let before = try FileScanner.scan(rootURL: root, rootID: rootID).photos
        var found = try await feature.matches(in: before, query: "alpha")
        XCTAssertEqual(found.count, 1)
        try Data("bravo".utf8).write(to: notes)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: notes.path)
        let after = try FileScanner.scan(rootURL: root, rootID: rootID).photos
        XCTAssertEqual(after.first?.companions.first?.size, before.first?.companions.first?.size)
        found = try await feature.matches(in: after, query: "bravo")
        XCTAssertEqual(found, Set(after.map(\.id)), "A same-size edit was answered from the cache")
        await composition.stop()
    }

    func testAChangedRemoteModificationTimeIsReadAgain() async throws {
        let calls = SearchCalls()
        let photo = remotePhoto("one.jpg")
        let composition = FrameComposition.fixture(files: SearchFiles(texts: [photo.id: "alpha"], calls: calls))
        try await composition.start()
        let feature = try XCTUnwrap(composition.runtime.service(FrameServices.PromptSearch.self, realm: "remote"))
        _ = try await feature.matches(in: [photo], query: "alpha")
        _ = try await feature.matches(in: [photo], query: "alpha")
        var reads = await calls.ids
        XCTAssertEqual(reads.count, 1)
        let edited = remotePhoto("one.jpg", companionModified: "2")
        let found = try await feature.matches(in: [edited], query: "alpha")
        XCTAssertEqual(found, [edited.id])
        reads = await calls.ids
        XCTAssertEqual(reads.count, 2, "A companion with a new modification time was answered from the cache")
        await composition.stop()
    }

    private func assertActionTargetsAreVisible(_ store: LibraryStore, file: StaticString = #filePath, line: UInt = #line) {
        let visible = Set(store.visiblePhotos.map(\.id))
        XCTAssertTrue(Set(store.actionPhotos.map(\.id)).isSubset(of: visible), "Delete would act on a hidden asset", file: file, line: line)
    }

    private func assertSelectionIsVisible(_ store: LibraryStore, file: StaticString = #filePath, line: UInt = #line) {
        let visible = Set(store.visiblePhotos.map(\.id))
        if let selected = store.selectedPhoto {
            XCTAssertTrue(visible.contains(selected.id), "The selected asset is hidden", file: file, line: line)
        }
        XCTAssertTrue(store.batchSelection.ids.isSubset(of: visible), "A hidden asset is still selected", file: file, line: line)
        XCTAssertTrue(Set(store.actionPhotos.map(\.id)).isSubset(of: visible), "Delete would act on a hidden asset", file: file, line: line)
    }

    private func pngData(text: String) -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var payload = Data("parameters".utf8)
        payload.append(0)
        payload.append(Data(text.utf8))
        appendChunk("tEXt", payload, to: &data)
        appendChunk("IEND", Data(), to: &data)
        return data
    }

    private func appendChunk(_ type: String, _ payload: Data, to data: inout Data) {
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(Data(type.utf8))
        data.append(payload)
        data.append(contentsOf: [0, 0, 0, 0])
    }
}

private func searchGate() -> KeyedGate { KeyedGate(failure: "Search read did not start", timeout: BridgeError("Fixture timeout")) }

/// Every companion-text read, in order.
private actor SearchCalls {
    private(set) var ids: [String] = []

    /// Records a read and returns how many times this asset has now been read.
    func record(_ id: String) -> Int {
        ids.append(id)
        return ids.filter { $0 == id }.count
    }
}

/// Answers companion text by asset id. `hold` runs before each answer with that asset's read count, and the
/// first read of an asset in `failsFirstRead` answers as a companion that could not be read.
private struct SearchFiles: RemoteFileReading {
    let texts: [String: String]
    let calls: SearchCalls
    var hold: @Sendable (PhotoItem, Int) async -> Void = { _, _ in }
    var failsFirstRead: Set<String> = []

    func resolve(_ photo: PhotoItem, includeCompanions: Bool, allowVideo: Bool, priority: Int) async throws -> PhotoItem {
        throw BridgeError("Fixture downloads are unavailable.")
    }
    func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry] { [] }
    func cachedMedia(_ photo: PhotoItem) async -> PhotoItem? { nil }
    func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText] {
        let call = await calls.record(photo.id)
        await hold(photo, call)
        let name = photo.companions.first?.url.lastPathComponent ?? ""
        if call == 1, failsFirstRead.contains(photo.id) {
            return [BridgeCompanionText(name: name, text: RelayRemoteClient.unreadableCompanionPrefix + "The connection timed out.")]
        }
        return [BridgeCompanionText(name: name, text: texts[photo.id] ?? "")]
    }
    func pin(_ photo: PhotoItem?) async {}
}
