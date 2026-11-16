import Foundation
import CompositionFixtures
import SwiftData
import XCTest
@testable import FrameKit

final class AssetTests: XCTestCase {
  func testScannerUsesSharedCompanionFixturesIncludingIndependentDocuments() throws {
    for sample in CompanionGroupingFixture.all {
      let root = try fixture(sample.files)
      let photos = try FileScanner.scan(rootURL: root, rootID: UUID()).photos
      var groups: [String: [String]] = [:]
      for photo in photos where !photo.companions.isEmpty { groups[photo.relativePath] = photo.companions.map(\.relativePath) }
      XCTAssertEqual(groups, sample.groups, sample.name)
      for name in sample.files where ["md", "html", "htm"].contains((name as NSString).pathExtension) {
        let document = try XCTUnwrap(photos.first { $0.relativePath == name }, sample.name)
        XCTAssertTrue(document.companions.isEmpty)
      }
    }
  }

  private func fixture(_ names: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameAssets-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in names {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data((name.hasSuffix("json") ? "{\"prompt\":\"test\"}" : "image-data").utf8).write(to: url)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func testExactJSONPreferredAndAmbiguousStemsNotClaimed() throws {
    let root = try fixture(["one.jpg", "one.json", "one.jpg.json", "two.jpg", "two.png", "two.json", "three.PNG", "three.JSON", "alone.json"])
    let scan = try FileScanner.scan(rootURL: root, rootID: UUID())
    XCTAssertEqual(scan.photos.count, 4)
    XCTAssertEqual(scan.photos.first { $0.name == "one.jpg" }?.sidecar?.url.lastPathComponent, "one.jpg.json")
    XCTAssertEqual(scan.photos.first { $0.name == "one.jpg" }?.companions.count, 2)
    XCTAssertNil(scan.photos.first { $0.name == "two.jpg" }?.sidecar)
    XCTAssertNil(scan.photos.first { $0.name == "two.png" }?.sidecar)
    XCTAssertEqual(scan.photos.first { $0.name == "three.PNG" }?.sidecar?.url.lastPathComponent, "three.JSON")
    XCTAssertEqual(scan.rootFolder.photoCount, 4)
  }
  func testArbitraryCompanionsUseLongestUnambiguousDotPrefix() throws {
    let root = try fixture(["name1.png", "name1.prompt.json", "name1.xyz.json", "name1.qqq.txt", "name1.bin",
      "name10.txt", "name1x.txt", "nested/name1.txt", "name1.deep.png", "name1.deep.qqq.txt",
      "twin.jpg", "twin.png", "twin.qqq.txt", "twin.jpg.notes.txt", "a.jpg", "a.jpg.png", "a.jpg.json"])
    let photos = try FileScanner.scan(rootURL: root, rootID: UUID()).photos
    func companions(_ name: String) -> Set<String> {
      Set(photos.first { $0.name == name }!.companions.map { $0.url.lastPathComponent })
    }
    XCTAssertEqual(companions("name1.png"), ["name1.prompt.json", "name1.xyz.json", "name1.qqq.txt", "name1.bin"])
    XCTAssertEqual(companions("name1.deep.png"), ["name1.deep.qqq.txt"])
    XCTAssertEqual(companions("twin.jpg"), ["twin.jpg.notes.txt"])
    XCTAssertTrue(companions("twin.png").isEmpty)
    XCTAssertEqual(companions("a.jpg"), ["a.jpg.json"])
    XCTAssertTrue(companions("a.jpg.png").isEmpty)
    let paths = photos.flatMap(\.companions).map(\.relativePath)
    XCTAssertEqual(Set(paths).count, paths.count)
  }
  func testWholeCompanionGroupArchivesRestoresExportsAndDeletesTogether() async throws {
    let names = ["name1.png", "name1.prompt.json", "name1.xyz.json", "name1.qqq.txt", "name1.bin"]
    let root = try fixture(names)
    let id = UUID()
    let photo = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: id).photos.first)
    let metadata = await ImageMetadataReader.read(photo: photo)
    XCTAssertEqual(Set(metadata.companions.map(\.name)), Set(names.dropFirst()))
    XCTAssertEqual(metadata.companions.first { $0.name == "name1.qqq.txt" }?.text, "image-data")
    try ArchiveService.archive(photo, root: root)
    let archived = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: id).photos.first)
    XCTAssertEqual(archived.exportMembers.count, 5)
    try ArchiveService.restore(archived, root: root)
    let restored = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: id).photos.first)
    let destination = root.appendingPathComponent("export")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try AssetExporter.export(AssetExporter.plan(restored, folder: destination))
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)), Set(names))
    let trash = root.appendingPathComponent("test-trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    let result = await BatchTrash.move([restored]) { source in
      let target = trash.appendingPathComponent(source.lastPathComponent)
      try FileManager.default.moveItem(at: source, to: target)
      return target
    }
    XCTAssertEqual(result.successes.first?.members.count, 5)
    XCTAssertTrue(names.allSatisfy { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
    XCTAssertEqual(BatchTrash.restore(result.successes).restored.count, 1)
    XCTAssertTrue(names.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
  }
  func testSymlinkJSONIsNotPairedAndMetadataInvalidatesSeparately() throws {
    let root = try fixture(["a.jpg", "real.json"])
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a.json"), withDestinationURL: root.appendingPathComponent("real.json"))
    XCTAssertNil(try FileScanner.scan(rootURL: root, rootID: UUID()).photos[0].sidecar)
    try FileManager.default.removeItem(at: root.appendingPathComponent("a.json"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("a.json"))
    let id = UUID()
    let before = try FileScanner.scan(rootURL: root, rootID: id).photos[0]
    try Data("{\"new\":true}".utf8).write(to: root.appendingPathComponent("a.json"))
    let after = try FileScanner.scan(rootURL: root, rootID: id).photos[0]
    XCTAssertEqual(before.contentID, after.contentID)
    XCTAssertNotEqual(before.metadataContentID, after.metadataContentID)
    XCTAssertThrowsError(try before.sidecar!.validate())
  }
  func testJSONErrorsAndLimits() throws {
    let root = try fixture(["bad.json"])
    let url = root.appendingPathComponent("bad.json")
    try Data("not json".utf8).write(to: url)
    XCTAssertTrue(SidecarReader.read(try .snapshot(url, relativePath: "bad.json")).contains("Cannot preview"))
    try Data(repeating: 32, count: SidecarReader.maximumBytes + 1).write(to: url)
    XCTAssertTrue(SidecarReader.read(try .snapshot(url, relativePath: "bad.json")).contains("2 MiB"))
  }
  func testArchivePairSurvivesScanAndRestoreAndNewSameName() throws {
    let root = try fixture(["nested/a.jpg", "nested/a.json"])
    let id = UUID()
    let photo = try FileScanner.scan(rootURL: root, rootID: id).photos[0]
    try ArchiveService.archive(photo, root: root)
    let scan = try FileScanner.scan(rootURL: root, rootID: id)
    XCTAssertTrue(scan.warnings.isEmpty, scan.warnings.joined(separator: "\n"))
    let archived = try XCTUnwrap(scan.photos.first)
    XCTAssertEqual(scan.photos.count, 1)
    XCTAssertEqual(scan.rootFolder.photoCount, 0)
    XCTAssertNotEqual(photo.id, archived.id)
    XCTAssertEqual(photo.favoriteID, archived.favoriteID)
    XCTAssertTrue(PhotoQuery.visiblePhotos(in: scan.photos, folderRelativePath: "", filter: .all, favorites: []).isEmpty)
    XCTAssertEqual(PhotoQuery.visiblePhotos(in: scan.photos, folderRelativePath: "", filter: .archive, favorites: []).count, 1)
    try Data("new-original".utf8).write(to: photo.url)
    let conflict = try FileScanner.scan(rootURL: root, rootID: id)
    XCTAssertEqual(Set(conflict.photos.map(\.id)).count, 2)
    XCTAssertThrowsError(try ArchiveService.restore(archived, root: root))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nested/a.json").path))
    try FileManager.default.removeItem(at: photo.url)
    try ArchiveService.restore(archived, root: root)
    let restored = try FileScanner.scan(rootURL: root, rootID: id)
    XCTAssertEqual(restored.photos.first?.id, photo.id)
    XCTAssertNotNil(restored.photos.first?.sidecar)
    XCTAssertTrue(restored.warnings.isEmpty)
  }
  func testExistingArchiveFolderIsNeverAdopted() throws {
    let root = try fixture(["a.jpg", "Archive/existing.png"])
    let scan = try FileScanner.scan(rootURL: root, rootID: UUID())
    XCTAssertEqual(scan.photos.count, 2)
    XCTAssertThrowsError(try ArchiveService.archive(scan.photos.first { $0.name == "a.jpg" }!, root: root))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.jpg").path))
  }
  func testArchiveRollbackAndMovedRootRecovery() throws {
    let root = try fixture(["a.jpg", "a.json"])
    let id = UUID()
    let photo = try FileScanner.scan(rootURL: root, rootID: id).photos[0]
    XCTAssertThrowsError(try ArchiveService.archive(photo, root: root, move: { source, target in
      if source.pathExtension == "json" { throw CocoaError(.fileWriteOutOfSpace) }
      try FileManager.default.moveItem(at: source, to: target)
    }))
    XCTAssertTrue(photo.exportMembers.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    try ArchiveService.archive(photo, root: root)
    let movedRoot = root.appendingPathExtension("moved")
    try FileManager.default.moveItem(at: root, to: movedRoot)
    defer { try? FileManager.default.removeItem(at: movedRoot) }
    let moved = try FileScanner.scan(rootURL: movedRoot, rootID: id)
    XCTAssertTrue(moved.warnings.isEmpty, moved.warnings.joined(separator: "\n"))
    XCTAssertEqual(moved.photos.count, 1)
    try ArchiveService.restore(XCTUnwrap(moved.photos.first), root: movedRoot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("a.json").path))
  }
  func testGroupedTrashRollsBackThenUndoRestoresPair() async throws {
    let root = try fixture(["a.jpg", "a.json"])
    let photo = try FileScanner.scan(rootURL: root, rootID: UUID()).photos[0]
    let trash = root.appendingPathComponent("test-trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    let failed = await BatchTrash.move([photo], operation: { source in
      if source.pathExtension == "json" { throw CocoaError(.fileWriteNoPermission) }
      let target = trash.appendingPathComponent(source.lastPathComponent)
      try FileManager.default.moveItem(at: source, to: target); return target
    })
    XCTAssertEqual(failed.failures.count, 1)
    XCTAssertTrue(failed.successes.isEmpty)
    XCTAssertTrue(photo.exportMembers.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    let result = await BatchTrash.move([photo], operation: { source in
      let target = trash.appendingPathComponent(source.lastPathComponent)
      try FileManager.default.moveItem(at: source, to: target); return target
    })
    XCTAssertEqual(result.successes.first?.members.count, 2)
    try Data("occupied".utf8).write(to: root.appendingPathComponent("a.json"))
    XCTAssertEqual(BatchTrash.restore(result.successes).failed.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: photo.url.path))
    try FileManager.default.removeItem(at: root.appendingPathComponent("a.json"))
    XCTAssertEqual(BatchTrash.restore(result.successes).restored.count, 1)
  }
  func testRollbackCollisionRetainsExplicitRecovery() async throws {
    let root = try fixture(["a.jpg", "a.json"])
    let photo = try FileScanner.scan(rootURL: root, rootID: UUID()).photos[0]
    let trash = root.appendingPathComponent("retained")
    let result = await BatchTrash.move([photo], operation: { source in
      if source.pathExtension == "json" {
        try Data("new occupant".utf8).write(to: photo.url)
        throw CocoaError(.fileWriteNoPermission)
      }
      try FileManager.default.moveItem(at: source, to: trash); return trash
    })
    XCTAssertEqual(result.partialRecoveries.count, 1)
    XCTAssertTrue(result.failures[0].reason.contains(trash.path))
    XCTAssertEqual(try Data(contentsOf: photo.url), Data("new occupant".utf8))
    try FileManager.default.removeItem(at: photo.url)
    XCTAssertEqual(BatchTrash.restore(result.partialRecoveries).restored.count, 1)
  }
  func testPairedExportReplacementRollbackAndStaleConsent() throws {
    let root = try fixture(["source/a.jpg", "source/a.json", "destination/a.jpg", "destination/a.json"])
    let photo = try FileScanner.scan(rootURL: root.appendingPathComponent("source"), rootID: UUID()).photos[0]
    let destination = root.appendingPathComponent("destination")
    let oldImage = destination.appendingPathComponent("a.jpg")
    let oldJSON = destination.appendingPathComponent("a.json")
    try Data("old-image".utf8).write(to: oldImage)
    try Data("old-json".utf8).write(to: oldJSON)
    let plan = try AssetExporter.plan(photo, folder: destination)
    XCTAssertEqual(plan.replacementNames, ["a.jpg", "a.json"])
    XCTAssertThrowsError(try AssetExporter.export(plan, copy: { source, target in
      if target.pathExtension == "json" { throw CocoaError(.fileWriteOutOfSpace) }
      try ExactCopyExporter.export(source: source, destination: target)
    }))
    XCTAssertEqual(try Data(contentsOf: oldImage), Data("old-image".utf8))
    XCTAssertEqual(try Data(contentsOf: oldJSON), Data("old-json".utf8))
    let fresh = try AssetExporter.plan(photo, folder: destination)
    try AssetExporter.export(fresh)
    XCTAssertEqual(try Data(contentsOf: oldJSON), try Data(contentsOf: photo.sidecar!.url))
    XCTAssertEqual(try Data(contentsOf: oldImage), try Data(contentsOf: photo.url))
    XCTAssertThrowsError(try AssetExporter.export(plan))
    XCTAssertThrowsError(try AssetExporter.plan(photo, folder: photo.url.deletingLastPathComponent()))
  }
  func testPairedExportRejectsUnrelatedDestinationJSON() throws {
    let root = try fixture(["source/a.jpg", "source/a.jpg.json", "destination/a.json"])
    let photo = try FileScanner.scan(rootURL: root.appendingPathComponent("source"), rootID: UUID()).photos[0]
    XCTAssertThrowsError(try AssetExporter.plan(photo, folder: root.appendingPathComponent("destination")))
  }
  @MainActor func testStoreArchiveAndRestoreKeepsFavoriteAndSelectsVisibleAsset() async throws {
    let root = try fixture(["a.jpg", "a.json"])
    let container = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: UserDefaults(suiteName: "FrameAssetsTest.\(UUID())")!)
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    store.setFileTypeFilter(.images)
    store.select(try XCTUnwrap(store.visiblePhotos.first)); store.toggleFavorite()
    await store.archiveSelection()
    XCTAssertTrue(store.visiblePhotos.isEmpty)
    store.setFilter(.archive)
    XCTAssertEqual(store.visiblePhotos.count, 1)
    XCTAssertTrue(store.canArchive)
    XCTAssertEqual(store.batchSelection.ids, [store.photos[0].id])
    XCTAssertTrue(store.isFavorite(store.photos[0]))
    store.select(store.photos[0])
    await store.archiveSelection()
    XCTAssertTrue(store.visiblePhotos.isEmpty)
    store.setFilter(.favorites)
    XCTAssertEqual(store.visiblePhotos.count, 1)
    XCTAssertNotNil(store.visiblePhotos.first?.sidecar)
    await store.shutdown()
  }
}
