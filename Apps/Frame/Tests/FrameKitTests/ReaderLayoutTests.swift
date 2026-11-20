import SwiftData
import XCTest
@testable import FrameKit

/// The store behaviour behind the two-column reader: folded sidecars, folder tiles, kind counts and the
/// Files/Icons rules for choosing files and folders.
@MainActor
final class ReaderLayoutTests: XCTestCase {
  /// The catalog must outlive every store that reads it.
  private var catalogs: [ModelContainer] = []
  private func makeStore(_ names: [String], folders: [String] = []) async throws -> (LibraryStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameReader-\(UUID())")
    for folder in folders {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in names {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data((name.hasSuffix(".json") ? #"{"prompt":"lagoon"}"# : "fixture").utf8).write(to: url)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let suite = "FrameReader.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "localIncludesSubfolders")
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let model = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    catalogs.append(model)
    let store = LibraryStore(defaults: defaults)
    await store.start(modelContext: model.mainContext)
    await store.openRoot(root)
    for _ in 0..<200 where store.localFolders?.results[""] == nil || store.isScanning {
      try await Task.sleep(for: .milliseconds(5))
    }
    return (store, root)
  }

  func testHiddenFilesAndFoldersShareOneVisit() async throws {
    let (store, _) = try await makeStore([".notes.md", "visible.md"], folders: [".private", "next"])
    XCTAssertEqual(store.treeFiles(in: "").map(\.name), ["visible.md"])
    XCTAssertEqual(store.subfolders.map(\.name), ["next"])
    XCTAssertEqual(store.hiddenCount(in: ""), 2)
    store.revealHidden(in: "")
    XCTAssertEqual(Set(store.visiblePhotos.map(\.name)), [".notes.md", "visible.md"])
    XCTAssertEqual(Set(store.subfolders.map(\.name)), [".private", "next"])
    store.selectFolder("next")
    store.selectFolder("")
    XCTAssertEqual(store.hiddenCount(in: ""), 2)
    await store.shutdown()
  }

  func testSidecarsAreFoldedIntoTheirFileUntilShown() async throws {
    let (store, _) = try await makeStore(["glass.png", "glass.png.json", "notes.md"])
    XCTAssertEqual(Set(store.visiblePhotos.map(\.name)), ["glass.png", "notes.md"])
    XCTAssertEqual(Set(store.treeFiles(in: "").map(\.name)), ["glass.png", "notes.md"])
    XCTAssertEqual(store.folderFileCount, 2)
    let glass = try XCTUnwrap(store.visiblePhotos.first { $0.name == "glass.png" })
    XCTAssertEqual(store.companionItems(of: glass).map(\.name), ["glass.png.json"])
    XCTAssertEqual(glass.exportMembers.map { $0.url.lastPathComponent }, ["glass.png", "glass.png.json"],
                   "An operation on the file still carries its sidecar")
    store.setShowsSidecarFiles(true)
    XCTAssertEqual(Set(store.visiblePhotos.map(\.name)), ["glass.png", "glass.png.json", "notes.md"])
    XCTAssertEqual(store.treeFiles(in: "").count, 3)
    store.setShowsSidecarFiles(false)
    store.setViewMode(.contactSheet)
    let sidecar = try XCTUnwrap(store.companionItems(of: glass).first)
    store.openCompanion(sidecar)
    XCTAssertEqual(store.viewMode, .inspect)
    XCTAssertTrue(store.showsSidecarFiles, "Opening a sidecar lists sidecars again so it stays in reach")
    XCTAssertEqual(store.selectedPhoto?.name, "glass.png.json")
    await store.shutdown()
  }

  func testArchivingAFileWithAFoldedSidecarMovesBoth() async throws {
    let (store, root) = try await makeStore(["glass.png", "glass.png.json"])
    store.setViewMode(.inspect)
    XCTAssertEqual(store.actionPhotos.map(\.name), ["glass.png"])
    XCTAssertTrue(store.canArchive)
    await store.archiveSelection()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("glass.png").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("glass.png.json").path))
    await store.shutdown()
  }

  func testChoosingAFileOpensFilesModeAndChoosingAFolderKeepsTheMode() async throws {
    let (store, _) = try await makeStore(["a.md", "b.png", "Child/c.png"], folders: ["Child"])
    store.setViewMode(.contactSheet)
    let file = try XCTUnwrap(store.files(in: "").first { $0.name == "b.png" })
    store.showFile(file)
    XCTAssertEqual(store.viewMode, .inspect)
    XCTAssertEqual(store.selectedPhoto?.name, "b.png")
    store.setViewMode(.contactSheet)
    store.selectFolder("Child")
    for _ in 0..<200 where store.localFolders?.results["Child"] == nil { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(store.viewMode, .contactSheet)
    XCTAssertEqual(store.shownFolderName, "Child")
    await store.shutdown()
  }

  func testIconsModeListsSubfoldersFirstOnlyWhileNothingNarrowsTheFiles() async throws {
    let (store, _) = try await makeStore(["a.md", "b.png", "c.mp4", "Notes/n.md"], folders: ["Notes", "Travel"])
    store.setViewMode(.contactSheet)
    XCTAssertEqual(store.gridFolders.map(\.name), ["Notes", "Travel"])
    XCTAssertEqual(store.shownFolderName, store.rootName)
    let counts = store.kindCounts
    XCTAssertEqual(counts[.all], 3)
    XCTAssertEqual(counts[.documents], 1)
    XCTAssertEqual(counts[.images], 1)
    XCTAssertEqual(counts[.videos], 1)
    store.setFileTypeFilter(.images)
    XCTAssertTrue(store.gridFolders.isEmpty)
    XCTAssertEqual(store.kindCounts[.all], 3, "Kind counts ignore the kind filter they choose between")
    store.clearFileFilters()
    XCTAssertEqual(store.gridFolders.count, 2)
    await store.shutdown()
  }

  func testKindChipsAndDescriptions() {
    func item(_ name: String) -> PhotoItem {
      PhotoItem(id: name, rootID: UUID(), url: URL(fileURLWithPath: "/fixture/" + name), relativePath: name, folderRelativePath: "",
        name: name, format: .browsing(pathExtension: (name as NSString).pathExtension), fileSize: 1, createdAt: nil,
        modifiedAt: nil, fileIdentifier: nil)
    }
    XCTAssertEqual(item("notes.markdown").kindChip, "MD")
    XCTAssertEqual(item("page.htm").kindChip, "HTML")
    XCTAssertEqual(item("still.jpeg").kindChip, "JPG")
    XCTAssertEqual(item("data.json").kindChip, "JSON")
    XCTAssertEqual(item("README").kindChip, "FILE")
    XCTAssertEqual(item("glass.png").kindDescription, "PNG image")
    XCTAssertEqual(item("clip.mp4").kindDescription, "MP4 video")
    XCTAssertEqual(item("notes.md").kindDescription, "Markdown document")
    XCTAssertEqual(FileTypeFilter.all.kindTitle, "All kinds")
    XCTAssertEqual(FileTypeFilter.images.kindTitle, "Images")
  }
}
