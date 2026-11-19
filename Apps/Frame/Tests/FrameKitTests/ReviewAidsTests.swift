import AppKit
import BridgeProtocol
import SwiftUI
@testable import Frame
import SwiftData
import WebKit
import XCTest
@testable import FrameKit

/// The review aids: the changed marker's rules and storage, Source, and the Markdown outline.
@MainActor
final class ReviewAidsTests: XCTestCase {
  private var catalogs: [ModelContainer] = []
  private let baseline = Date(timeIntervalSince1970: 1_800_000_000)

  private func folder(_ names: [String], modified: Date? = nil) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameReviewAids-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    for name in names {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data((name.hasSuffix(".json") ? #"{"prompt":"lagoon"}"# : "fixture").utf8).write(to: url)
      try touch(url, modified ?? baseline.addingTimeInterval(-3_600))
    }
    return root
  }
  private func touch(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }
  private func catalog(tracking: Bool = true) throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = tracking
      ? try ModelContainer(for: FrameCatalogStore.schema, configurations: configuration)
      : try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self, configurations: configuration)
    catalogs.append(container)
    return container
  }
  private func store(_ container: ModelContainer, root: URL, subfolders: Bool = false) async throws -> LibraryStore {
    let suite = "FrameReviewAids.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(subfolders, forKey: "localIncludesSubfolders")
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = LibraryStore(defaults: defaults)
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    try await settle(store)
    return store
  }
  private func settle(_ store: LibraryStore) async throws {
    for _ in 0..<200 where store.localFolders?.results[""] == nil || store.isReadingFolder || store.isScanning {
      try await Task.sleep(for: .milliseconds(5))
    }
  }
  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  }
  private func reload(_ store: LibraryStore, until condition: () -> Bool) async throws {
    store.retrySelectedFolder()
    try await wait(condition)
  }
  private func file(_ store: LibraryStore, _ name: String, in folder: String = "") throws -> PhotoItem {
    try XCTUnwrap(store.files(in: folder).first { $0.name == name })
  }
  /// Shows a file in Files mode the way the window does: selecting it, then displaying it.
  private func display(_ store: LibraryStore, _ name: String, in folder: String = "") throws {
    store.showFile(try file(store, name, in: folder))
    store.noteDisplayed(try file(store, name, in: folder))
  }

  func testRules() {
    let opened = baseline.addingTimeInterval(100)
    XCTAssertFalse(ChangeTracking.isChanged(modified: baseline, baseline: baseline, opened: nil), "At the baseline is not changed")
    XCTAssertFalse(ChangeTracking.isChanged(modified: baseline.addingTimeInterval(-1), baseline: baseline, opened: nil))
    XCTAssertTrue(ChangeTracking.isChanged(modified: baseline.addingTimeInterval(1), baseline: baseline, opened: nil))
    XCTAssertFalse(ChangeTracking.isChanged(modified: opened, baseline: baseline, opened: opened))
    XCTAssertTrue(ChangeTracking.isChanged(modified: opened.addingTimeInterval(1), baseline: baseline, opened: opened))
    XCTAssertFalse(ChangeTracking.isChanged(modified: nil, baseline: baseline, opened: nil), "No modification time, no marker")
    XCTAssertFalse(ChangeTracking.isChanged(modified: opened, baseline: nil, opened: nil), "No baseline, no marker")
  }

  func testRemoteListingTimesAreRead() {
    XCTAssertEqual(ChangeTracking.parse("2026-11-16T21:00:00+00:00"), Date(timeIntervalSince1970: 1_794_862_800))
    XCTAssertEqual(ChangeTracking.parse("2026-11-16T21:00:00.250+00:00")?.timeIntervalSince1970 ?? 0, 1_794_862_800.25, accuracy: 0.001)
    XCTAssertEqual(ChangeTracking.parse("2026-11-16T21:00:00.123456+00:00")?.timeIntervalSince1970 ?? 0, 1_794_862_800.123, accuracy: 0.001)
    XCTAssertEqual(ChangeTracking.parse("2026-11-16T21:00:00.123456+00:00"), ChangeTracking.parse("2026-11-16T21:00:00.123456+00:00"))
    XCTAssertNil(ChangeTracking.parse("fixture"))
  }

  func testMarkerFollowsFirstListingDisplayAndLaterChanges() async throws {
    let root = try folder(["a.md", "b.png", "c.md"])
    let container = try catalog()
    let store = try await store(container, root: root)
    XCTAssertEqual(store.folderBaselines[""], baseline.addingTimeInterval(-3_600), "The baseline is the newest file time listed")
    XCTAssertFalse(store.files(in: "").contains(where: store.isChanged), "Files present at the first listing carry no marker")
    store.setViewMode(.contactSheet)

    try touch(root.appendingPathComponent("a.md"), baseline.addingTimeInterval(60))
    try touch(root.appendingPathComponent("c.md"), baseline.addingTimeInterval(30))
    try await reload(store) { (try? file(store, "a.md"))?.modifiedAt == baseline.addingTimeInterval(60) }
    XCTAssertTrue(store.isChanged(try file(store, "a.md")))
    XCTAssertTrue(store.isChanged(try file(store, "c.md")))
    XCTAssertFalse(store.isChanged(try file(store, "b.png")))

    // Selected in Icons mode, then another file chosen in the tree: the first was never displayed.
    store.select(try file(store, "a.md"))
    store.noteDisplayed(try file(store, "a.md"))
    store.showFile(try file(store, "b.png"))
    store.noteDisplayed(try file(store, "a.md"))
    XCTAssertEqual(store.viewMode, .inspect)
    XCTAssertTrue(store.isChanged(try file(store, "a.md")), "Only the file displayed in Files mode counts as opened")

    try display(store, "a.md")
    XCTAssertFalse(store.isChanged(try file(store, "a.md")))
    XCTAssertEqual(store.openedTimes[try file(store, "a.md").favoriteID], baseline.addingTimeInterval(60), "The file's own time is kept")

    store.setViewMode(.contactSheet)
    try touch(root.appendingPathComponent("a.md"), baseline.addingTimeInterval(120))
    try await reload(store) { (try? file(store, "a.md"))?.modifiedAt == baseline.addingTimeInterval(120) }
    XCTAssertTrue(store.isChanged(try file(store, "a.md")), "A later change brings the marker back")
    await store.shutdown()

    // Everything persists; a file deleted outside Frame loses its entry when its folder is listed again.
    let later = try await self.store(container, root: root)
    XCTAssertEqual(later.folderBaselines[""], baseline.addingTimeInterval(-3_600))
    XCTAssertTrue(later.isChanged(try file(later, "c.md")))
    try display(later, "c.md")
    let key = try file(later, "c.md").favoriteID
    XCTAssertNotNil(later.openedTimes[key])
    later.setViewMode(.contactSheet)
    try FileManager.default.removeItem(at: root.appendingPathComponent("c.md"))
    try await reload(later) { later.openedTimes[key] == nil }
    XCTAssertNil(later.openedTimes[key])
    XCTAssertFalse(try container.mainContext.fetch(FetchDescriptor<OpenedFileRecord>()).map(\.key).contains(key))
    await later.shutdown()
  }

  func testFileTimesAheadOfThisMacAreNotMarkedAtFirstListing() async throws {
    let ahead = Date().addingTimeInterval(400 * 86_400)
    let root = try folder(["remote-ish.md", "other.md"], modified: ahead)
    let store = try await store(try catalog(), root: root)
    XCTAssertEqual(store.folderBaselines[""], ahead)
    XCTAssertFalse(store.files(in: "").contains(where: store.isChanged), "Only file times are compared, never this Mac's clock")
    store.setViewMode(.contactSheet)
    try touch(root.appendingPathComponent("other.md"), ahead.addingTimeInterval(5))
    try await reload(store) { (try? file(store, "other.md"))?.modifiedAt == ahead.addingTimeInterval(5) }
    XCTAssertTrue(store.isChanged(try file(store, "other.md")))
    await store.shutdown()
  }

  func testTrashUndoAndArchiveRestoreKeepTheOpenedTime() async throws {
    let root = try folder(["a.md", "b.md"])
    let store = try await store(try catalog(), root: root)
    store.setViewMode(.contactSheet)
    try touch(root.appendingPathComponent("a.md"), baseline.addingTimeInterval(60))
    try await reload(store) { (try? file(store, "a.md"))?.modifiedAt == baseline.addingTimeInterval(60) }
    try display(store, "a.md")
    let key = try file(store, "a.md").favoriteID
    XCTAssertNotNil(store.openedTimes[key])

    await store.deleteSelection()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.md").path))
    try await reload(store) { store.files(in: "").count == 1 }
    XCTAssertNotNil(store.openedTimes[key], "A file Frame moved to the Trash keeps its entry")
    store.dismissNotice()
    await store.restoreLastTrash()
    try await reload(store) { store.files(in: "").count == 2 }
    XCTAssertFalse(store.isChanged(try file(store, "a.md")), "Undo brings the file back without a marker")

    try display(store, "a.md")
    await store.archiveSelection()
    try await reload(store) { store.files(in: "").count == 1 }
    XCTAssertNotNil(store.openedTimes[key], "A file Frame archived keeps its entry")
    store.setFilter(.archive)
    try await wait { store.visiblePhotos.count == 1 }
    store.select(try XCTUnwrap(store.visiblePhotos.first))
    await store.archiveSelection()
    store.setFilter(.all)
    try await reload(store) { store.files(in: "").count == 2 }
    XCTAssertFalse(store.isChanged(try file(store, "a.md")), "Restore brings the file back without a marker")
    await store.shutdown()
  }

  func testAWholeScanNeverDropsEntriesItCannotSee() async throws {
    // A package's contents are listed by the tree but skipped by the whole-library scan.
    let root = try folder(["top.md", "Notes.rtfd/inside.md"])
    let store = try await store(try catalog(), root: root)
    store.selectFolder("Notes.rtfd")
    try await wait { store.localFolders?.results["Notes.rtfd"] != nil }
    try touch(root.appendingPathComponent("Notes.rtfd/inside.md"), baseline.addingTimeInterval(60))
    try await reload(store) { (try? file(store, "inside.md", in: "Notes.rtfd"))?.modifiedAt == baseline.addingTimeInterval(60) }
    try display(store, "inside.md", in: "Notes.rtfd")
    let key = try file(store, "inside.md", in: "Notes.rtfd").favoriteID
    XCTAssertNotNil(store.openedTimes[key])
    store.selectFolder("")
    await store.setIncludesSubfolders(true)
    try await wait { store.includesSubfolders }
    // Entering Icons mode with Subfolders on scans the whole library.
    store.setViewMode(.contactSheet)
    try await wait { store.photos.contains { $0.relativePath == "top.md" } && !store.isScanning
      && !store.photos.contains { $0.relativePath == "Notes.rtfd/inside.md" } }
    XCTAssertFalse(store.photos.contains { $0.relativePath == "Notes.rtfd/inside.md" }, "The scan skips the package")
    XCTAssertNotNil(store.openedTimes[key], "Absence from the whole scan drops nothing")
    await store.shutdown()
  }

  private let early = "2026-11-16T20:00:00+00:00", late = "2026-11-16T21:00:00+00:00"
  private func remoteStore(_ container: ModelContainer, _ fixture: MarkerFixture) async -> LibraryStore {
    let client = RelayRemoteClient(transport: { await fixture.send($0) })
    let actions = FixtureRemoteActions(mutation: { photo, action, _ in
      XCTAssertEqual(action, "archive"); await fixture.archive(photo); return UUID()
    }, deletion: { photos, _ in await fixture.delete(photos); return [] },
    archive: { try await client.archivedAssets(source: $0, root: $1) })
    let suite = "FrameReviewAids.\(UUID())"
    addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let store = makeRemoteStore(defaults: UserDefaults(suiteName: suite)!, remoteFolderLoader: { try await client.list(source: $0, path: $1) },
                                actions: actions)
    addTeardownBlock { await client.shutdown() }
    await store.start(modelContext: container.mainContext)
    return store
  }

  func testPermanentRemoteDeleteDropsTheOpenedTimeAndArchiveKeepsIt() async throws {
    let fixture = MarkerFixture(), container = try catalog()
    await fixture.set("a.png", modified: early); await fixture.set("b.png", modified: early)
    let store = await remoteStore(container, fixture)
    await store.openRemote(fixture.source, path: "/photos")
    XCTAssertEqual(store.folderBaselines["/photos"], ChangeTracking.parse(early))
    await fixture.set("a.png", modified: late)
    await store.openRemote(fixture.source, path: "/photos", preserveSelection: true)
    let shown = try file(store, "a.png", in: "/photos"), key = shown.favoriteID
    store.showFile(shown); store.noteDisplayed(shown)
    XCTAssertEqual(store.openedTimes[key], ChangeTracking.parse(late))

    await store.deleteSelection()
    XCTAssertEqual(store.notice?.message, "1 deleted")
    XCTAssertNil(store.openedTimes[key], "A remote Delete cannot be undone, so nothing is kept for it")
    XCTAssertFalse(try container.mainContext.fetch(FetchDescriptor<OpenedFileRecord>()).contains { $0.key == key })
    // A new file at the same path is not taken for the one opened before.
    await fixture.set("a.png", modified: late)
    await store.openRemote(fixture.source, path: "/photos", preserveSelection: true)
    let arrived = try file(store, "a.png", in: "/photos")
    XCTAssertTrue(store.isChanged(arrived))

    // Archive can be undone by Restore: the entry is kept, and dropped once the archived file is deleted.
    store.showFile(arrived); store.noteDisplayed(arrived)
    XCTAssertNotNil(store.openedTimes[key])
    await store.archiveSelection()
    await store.openRemote(fixture.source, path: "/photos", preserveSelection: true)
    XCTAssertNil(store.files(in: "/photos").first { $0.name == "a.png" })
    XCTAssertNotNil(store.openedTimes[key], "A file Frame archived keeps its entry")
    store.setFilter(.archive)
    try await wait { store.visiblePhotos.count == 1 && !store.isScanning }
    store.select(try XCTUnwrap(store.visiblePhotos.first))
    await store.deleteSelection()
    XCTAssertNil(store.openedTimes[key])
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<OpenedFileRecord>()).isEmpty)
    await store.shutdown()
  }

  func testAnArchivedGroupsSidecarLosesItsOpenedTimeWhenDeletedForGood() async throws {
    let fixture = MarkerFixture(), container = try catalog()
    await fixture.set("a.png", modified: early); await fixture.set("a.png.json", modified: early)
    let store = await remoteStore(container, fixture)
    await store.openRemote(fixture.source, path: "/photos")
    await fixture.set("a.png.json", modified: late)
    await store.openRemote(fixture.source, path: "/photos", preserveSelection: true)
    let image = try file(store, "a.png", in: "/photos")
    let sidecar = try XCTUnwrap(store.companionItems(of: image).first), key = sidecar.favoriteID
    store.openCompanion(sidecar); store.noteDisplayed(sidecar)
    XCTAssertNotNil(store.openedTimes[key], "The sidecar was opened")
    store.showFile(image)
    await store.archiveSelection()
    await store.openRemote(fixture.source, path: "/photos", preserveSelection: true)
    XCTAssertNotNil(store.openedTimes[key], "Archive holds the sidecar's entry under its own path")
    store.setFilter(.archive)
    try await wait { store.visiblePhotos.count == 1 && !store.isScanning }
    let archived = try XCTUnwrap(store.visiblePhotos.first)
    XCTAssertTrue(archived.companions.allSatisfy { $0.relativePath.hasPrefix("/photos/Archive/") }, "Delete uses the stored paths")
    store.select(archived)
    await store.deleteSelection()
    XCTAssertEqual(store.notice?.message, "1 deleted")
    XCTAssertNil(store.openedTimes[key])
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<OpenedFileRecord>()).isEmpty)
    await store.shutdown()
  }

  func testAnEmptyRemoteFolderListedByExpandingGetsTheSameBaselineAsOpeningIt() async throws {
    let fixture = MarkerFixture()
    await fixture.set("a.png", modified: early)
    await fixture.addFolder("Opened"); await fixture.addFolder("Expanded")
    let store = await remoteStore(try catalog(), fixture)
    await store.openRemote(fixture.source, path: "/photos/Opened")
    XCTAssertEqual(store.folderBaselines["/photos/Opened"], .distantPast, "An empty folder's baseline is the distant past")
    await store.openRemote(fixture.source, path: "/photos")
    let tree = try XCTUnwrap(store.remoteFolders)
    XCTAssertNil(tree.cachedFiles(at: "/photos/Expanded"), "Never listed is not the same as empty")
    store.setRemoteFolderExpanded("/photos/Expanded", true)
    try await wait { tree.nodes["/photos/Expanded"]?.isLoaded == true && store.folderBaselines["/photos/Expanded"] != nil }
    XCTAssertEqual(tree.cachedFiles(at: "/photos/Expanded")?.count, 0)
    XCTAssertEqual(store.folderBaselines["/photos/Expanded"], .distantPast)
    // A file that arrives afterwards is new to both folders.
    await fixture.set("new.png", modified: late, in: "/photos/Expanded")
    await fixture.set("new.png", modified: late, in: "/photos/Opened")
    for folder in ["/photos/Expanded", "/photos/Opened"] {
      await store.openRemote(fixture.source, path: folder, preserveSelection: true)
      XCTAssertTrue(store.isChanged(try file(store, "new.png", in: folder)), folder)
    }
    await store.shutdown()
  }

  func testCatalogWithoutTheNewModelsHasNoMarkers() async throws {
    let root = try folder(["a.md"])
    let store = try await store(try catalog(tracking: false), root: root)
    XCTAssertTrue(store.folderBaselines.isEmpty)
    store.setViewMode(.contactSheet)
    try touch(root.appendingPathComponent("a.md"), baseline.addingTimeInterval(60))
    try await reload(store) { (try? file(store, "a.md"))?.modifiedAt == baseline.addingTimeInterval(60) }
    XCTAssertFalse(store.isChanged(try file(store, "a.md")))
    try display(store, "a.md")
    await store.shutdown()
  }

  func testFilesRowCountsWhatTheActionsReach() async throws {
    let root = try folder(["a.png", "b.png", "c.png"])
    let store = try await store(try catalog(), root: root)
    store.setViewMode(.contactSheet)
    store.updateGridSelection(Set(store.visiblePhotos.map(\.id)), currentID: store.visiblePhotos[0].id)
    XCTAssertEqual(store.selectionCountLabel, "3 selected")
    store.inspect(store.visiblePhotos[0])
    XCTAssertNil(store.selectionCountLabel, "One file on show, one file acted on")
    store.toggleSelectMode()
    store.toggleCurrentSelection()
    store.navigate(by: 1)
    store.toggleCurrentSelection()
    XCTAssertEqual(store.actionPhotos.count, 2)
    XCTAssertEqual(store.selectionCountLabel, "2 selected", "In Select mode the Files row says what Trash will reach")
    await store.shutdown()
  }

  func testSidecarRowsComeFromTheFilesOwnCompanions() {
    let store = LibraryStore(defaults: UserDefaults(suiteName: "FrameReviewAids.\(UUID())")!)
    let source = BridgeSource(id: String(repeating: "e", count: 64), name: "Host")
    let entry = BridgeEntry(name: "a.png", path: "/early/a.png", directory: false, size: 4, modified: "2026-11-16T21:00:00+00:00")
    let companion = BridgeEntry(name: "a.png.json", path: "/early/a.png.json", directory: false, size: 2, modified: "2026-11-16T21:00:00+00:00")
    let url = URL(string: "frame-remote://host/early/a.png.json")!
    var photo = PhotoItem(id: "a", rootID: UUID(), url: URL(string: "frame-remote://host/early/a.png")!, relativePath: "/early/a.png",
      folderRelativePath: "/early", name: "a.png", format: .png, fileSize: 4, createdAt: nil, modifiedAt: nil, fileIdentifier: nil,
      companions: [AssetFile(url: url, relativePath: "/early/a.png.json", size: 2, modifiedAt: nil, identifier: nil)])
    photo.remote = RemoteAssetReference(source: source, listingID: UUID(), entry: entry, companions: [companion])
    let items = store.companionItems(of: photo)
    XCTAssertEqual(items.map(\.name), ["a.png.json"], "No cached listing is needed")
    XCTAssertEqual(items.first?.companionOwnerID, "a")
    XCTAssertEqual(items.first?.remote?.entry, companion)
    XCTAssertEqual(items.first?.remote?.listingID, photo.remote?.listingID)
  }

  func testHidingSidecarsShowsTheOwnerOfTheOneOnShow() async throws {
    let root = try folder(["b.png", "glass.png", "glass.png.json"])
    let store = try await store(try catalog(), root: root)
    let glass = try file(store, "glass.png")
    let sidecar = try XCTUnwrap(store.companionItems(of: glass).first)
    store.openCompanion(sidecar)
    XCTAssertEqual(store.selectedPhoto?.name, "glass.png.json")
    store.setShowsSidecarFiles(false)
    XCTAssertEqual(store.selectedPhoto?.name, "glass.png")
    await store.shutdown()
  }

  func testKindCountsFollowTheFolder() async throws {
    let root = try folder(["a.md", "b.png"])
    let store = try await store(try catalog(), root: root)
    store.setViewMode(.contactSheet)
    XCTAssertEqual(store.kindCounts[.images], 1)
    XCTAssertEqual(store.folderFileCount, 2)
    try Data("x".utf8).write(to: root.appendingPathComponent("c.png"))
    try await reload(store) { store.files(in: "").count == 3 }
    XCTAssertEqual(store.kindCounts[.images], 2, "Cached counts are dropped when the files change")
    XCTAssertEqual(store.folderFileCount, 3)
    store.setFilter(.favorites)
    XCTAssertEqual(store.kindCounts[.all] ?? 0, 0)
    await store.shutdown()
  }

  func testSearchCommandBringsTheFieldBack() async throws {
    let root = try folder(["a.md"])
    let store = try await store(try catalog(), root: root)
    try await wait { store.isSearchAvailable }
    store.showsFolderOutline = false
    let requests = store.searchFocusRequests
    store.revealSearch()
    XCTAssertEqual(store.showsFolderOutline, true)
    XCTAssertFalse(store.isFocusMode)
    try await wait { store.searchFocusRequests > requests }
    XCTAssertEqual(store.searchFocusRequests, requests + 1, "The field is asked for the focus once it can exist")
    await store.shutdown()
  }

  func testSourceShowsTheFilesOwnText() throws {
    let markdown = Data("# Title\n\n## Part\n\n<b>bold</b>".utf8)
    let rendered = try DocumentHTML.page(markdown, extension: "md", referenceToken: "t")
    XCTAssertTrue(rendered.contains("<article class=\"markdown\">"))
    let source = try DocumentHTML.page(markdown, extension: "md", referenceToken: "t", source: true)
    XCTAssertTrue(source.hasPrefix("<style>" + DocumentHTML.theme + "</style><article><pre>"))
    XCTAssertTrue(source.contains("## Part"))
    XCTAssertTrue(source.contains("&lt;b&gt;bold&lt;/b&gt;"))
    let html = try DocumentHTML.page(Data("<h1>Page</h1>".utf8), extension: "html", referenceToken: "t", source: true)
    XCTAssertTrue(html.contains("&lt;h1&gt;Page&lt;/h1&gt;"))
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
  }

  func testCollapsingLibraryKeepsTheDisplayedMarkdownPage() async throws {
    let root = try folder([])
    let longSection = String(repeating: "Paragraph.\n\n", count: 100)
    try Data("## First\n\n\(longSection)\n## Second\n\n\(longSection)".utf8)
      .write(to: root.appendingPathComponent("notes.md"))
    let container = try catalog()
    let store = try await store(container, root: root)
    try display(store, "notes.md")
    let window = QuietWindow(size: NSSize(width: 1600, height: 720), styleMask: [.titled, .resizable])
    let renderer = store.documentRenderer
    let web = try XCTUnwrap(renderer.webView)
    var widthBeforeOutline: CGFloat?
    let observation = renderer.$outline.sink { headings in
      if headings.count == 2, widthBeforeOutline == nil { widthBeforeOutline = web.bounds.width }
    }
    defer { observation.cancel() }
    let host = NSHostingController(rootView: FrameRootView(store: store, modelContainer: container))
    window.contentViewController = host
    window.orderInOffscreen()
    defer { window.contentViewController = nil; window.orderOut(nil) }

    try await waitFor { renderer.outline.count == 2 && web.window === window }
    XCTAssertEqual(renderer.outline.count, 2)
    host.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(web.bounds.width, try XCTUnwrap(widthBeforeOutline), accuracy: 1)
    let originalParent = try XCTUnwrap(web.superview)
    _ = try await web.evaluateJavaScript("window.scrollTo(0, 500); window.pageMarker = 'original'")
    for visible in [false, true, false] {
      let oldWidth = web.bounds.width
      store.showsFolderOutline = visible
      try await waitFor { abs(web.bounds.width - oldWidth) > 10 }
      XCTAssertGreaterThan(abs(web.bounds.width - oldWidth), 10)
      XCTAssertTrue(web.superview === originalParent)
      let intact = try await web.evaluateJavaScript(
        "window.pageMarker === 'original' && scrollY > 0 && document.querySelector('article h2')?.textContent === 'First'") as? Bool
      XCTAssertEqual(intact, true)
    }
  }

  func testOutlineComesFromTheIsolatedWorldAndFollowsChoice() async throws {
    let root = try folder([])
    let sections = (1...6).map { "## Part \($0)\n\n" + String(repeating: "Line of text.\n\n", count: 30) }.joined()
    try Data("# Title\n\n\(sections)### Detail\n\nEnd.\n".utf8).write(to: root.appendingPathComponent("notes.md"))
    let renderer = DocumentRenderer()
    let window = QuietWindow(size: NSSize(width: 900, height: 600), styleMask: [.titled])
    window.contentView = renderer.webView
    defer { renderer.stop(); window.contentView = nil }
    renderer.show(path: "notes.md", location: .local(root))
    try await waitFor { renderer.outline.count == 7 }
    XCTAssertEqual(renderer.outline.map(\.title), (1...6).map { "Part \($0)" } + ["Detail"])
    XCTAssertEqual(renderer.outline.map(\.level), [2, 2, 2, 2, 2, 2, 3])
    XCTAssertEqual(renderer.activeHeading, 0)
    // The page's own world sees neither Frame's script nor its message handler.
    let pageSees = try await renderer.webView.evaluateJavaScript(
      "typeof window.frameOutlineGo + ' ' + typeof (window.webkit && window.webkit.messageHandlers.frameOutline)") as? String
    XCTAssertEqual(pageSees, "undefined undefined")
    renderer.scrollToHeading(3)
    try await Task.sleep(for: .milliseconds(400))
    let scrolled = try await renderer.webView.evaluateJavaScript("window.scrollY > 0") as? Bool
    XCTAssertEqual(scrolled, true)
    XCTAssertEqual(renderer.activeHeading, 3)
    renderer.setShowsSource(true)
    XCTAssertTrue(renderer.outline.isEmpty)
    try await waitFor { renderer.loading == false && renderer.webView.url != nil }
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(renderer.outline.isEmpty, "Source has no outline")
    let text = try await renderer.webView.evaluateJavaScript("document.querySelector('article pre')?.textContent ?? ''") as? String
    XCTAssertTrue(text?.contains("## Part 1") == true)
    renderer.setShowsSource(false)
    try await waitFor { renderer.outline.count == 7 }
    XCTAssertEqual(renderer.outline.count, 7)
  }

}

/// A remote library under /photos whose files the test changes. Archive moves a file and its companions into one
/// record, which the client reads back as RelayBar would send it.
private actor MarkerFixture {
  let source = BridgeSource(id: String(repeating: "e", count: 64), name: "Markers")
  private var files: [String: [String: String]] = ["/photos": [:]]
  private var folders: [String: [String]] = [:]
  private var records: [BridgeStoredAsset] = []
  func set(_ name: String, modified: String, in folder: String = "/photos") { files[folder, default: [:]][name] = modified }
  func addFolder(_ name: String) { folders["/photos", default: []].append(name); files["/photos/" + name] = [:] }
  func delete(_ photos: [PhotoItem]) {
    for photo in photos where photo.archiveID == nil {
      for name in [photo.name] + (photo.remote?.companions.map(\.name) ?? []) { files[photo.folderRelativePath]?[name] = nil }
    }
    records.removeAll { record in photos.contains { $0.archiveID == record.id } }
  }
  func archive(_ photo: PhotoItem) {
    guard let remote = photo.remote else { return }
    let id = UUID(), members = [remote.entry] + remote.companions
    for member in members { files[photo.folderRelativePath]?[member.name] = nil }
    records.append(BridgeStoredAsset(id: id, members: members.map {
      BridgeEntry(name: $0.name, path: "/photos/Archive/\(id)/" + $0.name, directory: false, size: $0.size, modified: $0.modified)
    }, originals: members.map(\.path)))
  }
  func send(_ request: BridgeRequest) -> BridgeResponse {
    var response = BridgeResponse()
    if request.operation == "collection" {
      response.listingID = UUID(); var result = BridgeAssetResult(); result.records = records; response.asset = result
      return response
    }
    guard request.operation == "list", let path = request.path else { return response }
    response.listingID = UUID()
    response.entries = (files[path] ?? [:]).sorted { $0.key < $1.key }.map {
      BridgeEntry(name: $0.key, path: path + "/" + $0.key, directory: false, size: 4, modified: $0.value, fingerprint: $0.value)
    } + (folders[path] ?? []).map { BridgeEntry(name: $0, path: path + "/" + $0, directory: true, size: 0, modified: "") }
    return response
  }
}
