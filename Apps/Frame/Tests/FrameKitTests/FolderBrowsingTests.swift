import BridgeProtocol
import SwiftData
import XCTest
@testable import FrameKit

@MainActor
final class FolderBrowsingTests: XCTestCase {
  private func defaults() -> UserDefaults {
    let suite = "FrameFolderBrowsing.\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "localIncludesSubfolders")
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return defaults
  }

  func testLocalFolderWithoutMediaShowsEveryRegularFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameFolderBrowsing-\(UUID())")
    let folder = root.appendingPathComponent("Notes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let names = ["notes.txt", "data.json", "script.py", "bundle.zip"]
    for name in names { try Data("fixture".utf8).write(to: folder.appendingPathComponent(name)) }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: defaults())
    await store.start(modelContext: model.mainContext)
    await store.openRoot(root)
    store.selectFolder("Notes")
    for _ in 0..<200 where store.localFolders?.results["Notes"] == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(Set(store.files(in: "Notes").map(\.name)), Set(names))
    XCTAssertEqual(Set(store.visiblePhotos.map(\.name)), Set(names))
    XCTAssertNotNil(store.selectedPhoto)
    XCTAssertEqual(store.viewMode, .contactSheet)
    XCTAssertTrue(store.folderIsSelected)
    store.setFileTypeFilter(.documents)
    XCTAssertEqual(Set(store.visiblePhotos.map(\.name)), ["notes.txt", "data.json", "script.py"])
    store.setFileTypeFilter(.images)
    XCTAssertTrue(store.visiblePhotos.isEmpty)
    XCTAssertEqual(store.folderFileCount, 4)
    XCTAssertTrue(store.hasFileFilters)
    let notes = try XCTUnwrap(store.files(in: "Notes").first { $0.name == "notes.txt" })
    store.selectFile(notes)
    XCTAssertEqual(store.visiblePhotos.count, 4, "An explicit sidebar selection must reveal a file hidden by a type filter")
    XCTAssertEqual(store.selectedPhoto?.name, "notes.txt")
    store.clearFileFilters()
    XCTAssertEqual(store.visiblePhotos.count, 4)
    XCTAssertNil(store.errorMessage)
    await store.shutdown()
  }

  func testRemoteFolderWithoutMediaUsesCompleteWireListing() async throws {
    let source = BridgeSource(id: String(repeating: "b", count: 64), name: "Folder fixture")
    let names = ["notes.txt", "data.json", "script.py", "bundle.zip"]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRemoteBrowsing-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let client = RelayRemoteClient(transport: { request in
      guard request.operation == "list", request.path == "/notes" else {
        throw BridgeError("Unexpected request: \(request.operation)")
      }
      var response = BridgeResponse()
      response.listingID = UUID()
      response.entries = names.map { BridgeEntry(name: $0, path: "/notes/" + $0,
        directory: false, size: 7, modified: "0", fingerprint: $0) }
      return response
    }, cacheRoot: root, sharedRoot: { root })
    let store = makeRemoteStore(defaults: defaults(), remoteFolderLoader: { source, path in
      try await client.list(source: source, path: path)
    })
    await store.openRemote(source, path: "/notes")
    XCTAssertEqual(Set(store.files(in: "/notes").map(\.name)), Set(names))
    XCTAssertEqual(Set(store.visiblePhotos.map(\.name)), Set(names))
    XCTAssertNotNil(store.selectedPhoto)
    store.setViewMode(.inspect)
    store.selectFolder("/notes")
    for _ in 0..<200 where store.viewMode != .contactSheet || store.isScanning {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(store.viewMode, .contactSheet)
    XCTAssertTrue(store.folderIsSelected)
    store.setFileTypeFilter(.other)
    XCTAssertEqual(store.visiblePhotos.map(\.name), ["bundle.zip"])
    XCTAssertFalse(store.canDelete)
    XCTAssertFalse(store.canArchive)
    XCTAssertNotNil(store.groupedActionHelp)
    XCTAssertNil(store.remoteError)
    await store.shutdown()
    await client.shutdown()
  }

  func testTypeAndFavoriteFiltersCombineWithoutHidingUnfilteredFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameMixedBrowsing-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["a.jpg", "a.jpg.json", "b.png", "notes.txt", "bundle.zip"] {
      try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: defaults())
    await store.start(modelContext: model.mainContext)
    await store.openRoot(root)
    XCTAssertEqual(store.visiblePhotos.count, 5)
    let companion = try XCTUnwrap(store.visiblePhotos.first { $0.name == "a.jpg.json" })
    XCTAssertNotNil(companion.companionOwnerID)
    store.select(companion)
    XCTAssertFalse(store.canDelete)
    XCTAssertFalse(store.canArchive)
    XCTAssertEqual(store.companionDescription(companion), "Companion of a.jpg")
    store.setViewMode(.contactSheet)
    let owner = try XCTUnwrap(store.visiblePhotos.first { $0.name == "a.jpg" })
    store.updateGridSelection([owner.id, companion.id], currentID: owner.id)
    XCTAssertEqual(store.selectedMemberCount, 2)
    XCTAssertEqual(store.selectedByteCount, 14)
    XCTAssertFalse(store.canDelete)
    XCTAssertFalse(store.canExport)
    store.deleteSelected()
    XCTAssertEqual(store.notice?.message, store.groupedActionHelp)
    store.setFileTypeFilter(.images)
    XCTAssertEqual(store.visiblePhotos.map(\.name), ["a.jpg", "b.png"])
    store.toggleFavorite()
    store.setFilter(.favorites)
    XCTAssertEqual(store.visiblePhotos.map(\.name), ["a.jpg"])
    store.setFileTypeFilter(.documents)
    XCTAssertTrue(store.visiblePhotos.isEmpty)
    store.selectFile(companion)
    XCTAssertTrue(store.visiblePhotos.contains { $0.id == companion.id }, "An explicit selection must clear a favorite filter that hides it")
    XCTAssertFalse(store.hasFileFilters && store.visiblePhotos.isEmpty)
    store.clearFileFilters()
    XCTAssertEqual(store.visiblePhotos.count, 5)
    XCTAssertFalse(store.hasFileFilters)
    await store.shutdown()
  }

  func testRemoteRecursiveScanCountsAndBoundsGeneralFiles() async throws {
    let source = BridgeSource(id: String(repeating: "c", count: 64), name: "Scan fixture")
    let tree = RemoteFolderIndex(source: source, path: "/notes", loader: { _, path in
      let files = (0..<3).map { number in
        PhotoItem(id: "\(path)/\(number).txt", rootID: UUID(), url: URL(fileURLWithPath: "/fixture/\(number).txt"),
          relativePath: "\(path)/\(number).txt", folderRelativePath: path, name: "\(number).txt", format: .text,
          fileSize: 7, createdAt: nil, modifiedAt: nil, fileIdentifier: nil)
      }
      let children = path == "/notes" ? [FolderNode(id: "/notes/child", name: "child", relativePath: "/notes/child", photoCount: 0, children: [])] : []
      return ScanResult(photos: [], rootFolder: FolderNode(id: path, name: path, relativePath: path, photoCount: 0, children: children), files: files)
    })
    var result: RemoteScanSnapshot?
    try await RemoteSubfolderScan.run(index: tree, path: "/notes") { result = $0 }
    XCTAssertEqual(result?.files.count, 6)
    XCTAssertEqual(result?.photos.count, 0)
    XCTAssertEqual(result?.folders, 2)
    try await RemoteSubfolderScan.run(index: tree, path: "/notes", maximumAssets: 4) { result = $0 }
    XCTAssertEqual(result?.files.count, 4)
    XCTAssertTrue(result?.issues.first?.contains("4 files") == true)
    await tree.shutdown()
  }

  func testMissingLocalFolderReportsErrorAndRetryRecovers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameMissingFolder-\(UUID())")
    let child = root.appendingPathComponent("Child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: defaults())
    await store.start(modelContext: model.mainContext)
    await store.openRoot(root)
    try FileManager.default.removeItem(at: child)
    store.selectFolder("Child")
    for _ in 0..<200 where store.folderReadError == nil { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNotNil(store.folderReadError)
    XCTAssertFalse(store.isReadingFolder)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data("recovered".utf8).write(to: child.appendingPathComponent("notes.txt"))
    store.retrySelectedFolder()
    for _ in 0..<200 where store.visiblePhotos.isEmpty || store.isReadingFolder { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNil(store.folderReadError)
    XCTAssertEqual(store.visiblePhotos.map(\.name), ["notes.txt"])
    await store.shutdown()
  }

  func testFailedRemoteFolderReportsErrorAndRetryRecovers() async throws {
    let fixture = FailingFolderFixture()
    let store = makeRemoteStore(defaults: defaults(), remoteFolderLoader: { _, path in try await fixture.load(path) })
    await store.openRemote(BridgeSource(id: String(repeating: "d", count: 64), name: "Retry fixture"), path: "/notes")
    XCTAssertEqual(store.folderReadError, "Permission denied")
    XCTAssertFalse(store.isReadingFolder)
    await fixture.allow()
    store.retrySelectedFolder()
    for _ in 0..<200 where store.folderReadError != nil || store.isReadingFolder { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNil(store.folderReadError)
    XCTAssertEqual(store.visiblePhotos.map(\.name), ["notes.txt"])
    await store.shutdown()
  }
}

private actor FailingFolderFixture {
  private var allowed = false
  func allow() { allowed = true }
  func load(_ path: String) throws -> ScanResult {
    guard allowed else { throw BridgeError("Permission denied") }
    let file = PhotoItem(id: path + "/notes.txt", rootID: UUID(), url: URL(fileURLWithPath: "/fixture/notes.txt"),
      relativePath: path + "/notes.txt", folderRelativePath: path, name: "notes.txt", format: .text,
      fileSize: 7, createdAt: nil, modifiedAt: nil, fileIdentifier: nil)
    return ScanResult(photos: [], rootFolder: FolderNode(id: path, name: "notes", relativePath: path, photoCount: 0, children: []), files: [file])
  }
}
