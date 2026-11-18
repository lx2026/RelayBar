import Foundation
import SwiftData
import XCTest
@testable import FrameKit

final class BatchSelectionTests: XCTestCase {
  private func fixtures(_ count: Int) throws -> (URL, [PhotoItem]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameBatch-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<count {
      try Data(repeating: UInt8(index % 255), count: 20).write(to: root.appendingPathComponent("\(index).png"))
    }
    return (root, try FileScanner.scan(rootURL: root, rootID: UUID()).photos)
  }
  func testActivePreviewAlwaysBelongsToSelection() {
    var selection = MediaSelection()
    selection.update(ids: ["a", "b"], currentID: "c")
    XCTAssertEqual(selection.ids, ["a", "b"])
    XCTAssertEqual(selection.currentID, "a")
    selection.update(ids: [], currentID: "c")
    XCTAssertTrue(selection.ids.isEmpty)
    XCTAssertNil(selection.currentID)
    selection.replace(with: "d")
    XCTAssertEqual(selection.ids, ["d"])
    selection.reconcile(with: ["a", "b"])
    XCTAssertNil(selection.currentID)
    XCTAssertTrue(selection.ids.isEmpty)
    selection.preview("a")
    XCTAssertEqual(selection.ids, ["a"])
    XCTAssertEqual(selection.currentID, "a")
  }
  func testLargeSelectionDoesNotNeedMediaDecoding() {
    let ids = (0..<10_000).map { "file-\($0)" }
    var selection = MediaSelection()
    let start = ContinuousClock.now
    selection.update(ids: Set(ids), currentID: ids[3])
    selection.reconcile(with: ids)
    XCTAssertEqual(selection.ids.count, 10_000)
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
  }
  func testPartialTrashFailureAndGroupedRestore() async throws {
    let (root, photos) = try fixtures(3)
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("TestTrash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let result = await BatchTrash.move(photos, operation: { source in
      if source.lastPathComponent == "1.png" { throw CocoaError(.fileWriteNoPermission) }
      let destination = trash.appendingPathComponent(source.lastPathComponent)
      try FileManager.default.moveItem(at: source, to: destination)
      return destination
    })
    XCTAssertEqual(result.successes.count, 2)
    XCTAssertEqual(result.failures.map { $0.photo.name }, ["1.png"])
    XCTAssertTrue(result.unprocessed.isEmpty)
    let restored = BatchTrash.restore(result.successes)
    XCTAssertEqual(restored.restored.count, 2)
    XCTAssertTrue(restored.errors.isEmpty)
    XCTAssertTrue(photos.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
  }
  func testTrashRefusesReplacedOrChangedSource() async throws {
    let (root, photos) = try fixtures(2)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: photos[0].url)
    try Data("replacement".utf8).write(to: photos[0].url)
    try Data("modified content".utf8).write(to: photos[1].url)
    let result = await BatchTrash.move(photos, operation: { _ in
      XCTFail("A stale file identity must never reach Trash")
      throw CocoaError(.fileWriteUnknown)
    })
    XCTAssertEqual(result.failures.count, 2)
    XCTAssertTrue(result.successes.isEmpty)
  }
  func testCancelledTrashLeavesCompletedMovesUndoableAndReportsUnprocessed() async throws {
    let (root, photos) = try fixtures(100)
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("TestTrash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let task = Task {
      await BatchTrash.move(photos, operation: { source in
        let destination = trash.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
      }, progress: { count in
        if count == 1 { try? await Task.sleep(for: .milliseconds(100)) }
      })
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    let result = await task.value
    XCTAssertGreaterThan(result.successes.count, 0)
    XCTAssertGreaterThan(result.unprocessed.count, 0)
    XCTAssertEqual(result.successes.count + result.unprocessed.count, 100)
    XCTAssertEqual(BatchTrash.restore(result.successes).restored.count, result.successes.count)
  }
  func testRestoreReportsOccupiedAndMissingTrashEntries() async throws {
    let (root, photos) = try fixtures(2)
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("TestTrash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let moved = await BatchTrash.move(photos, operation: { source in
      let destination = trash.appendingPathComponent(source.lastPathComponent)
      try FileManager.default.moveItem(at: source, to: destination)
      return destination
    })
    try Data("occupied".utf8).write(to: photos[0].url)
    try FileManager.default.removeItem(at: moved.successes[1].trashURL)
    let result = BatchTrash.restore(moved.successes)
    XCTAssertEqual(result.errors.count, 2)
    XCTAssertEqual(result.failed.count, 1, "Missing Trash entries must not shadow older Undo groups")
    XCTAssertTrue(result.restored.isEmpty)
    XCTAssertEqual(try Data(contentsOf: photos[0].url), Data("occupied".utf8))
  }
  @MainActor func testBrowseBatchAndInspectSingularActionsAndGroupedUndo() async throws {
    let (root, _) = try fixtures(4)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: UserDefaults(suiteName: "FrameBatchTest.\(UUID())")!)
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    await store.setIncludesSubfolders(false)
    store.setViewMode(.contactSheet)
    XCTAssertEqual(store.viewMode, .contactSheet)
    let photos = store.photos
    let ids = Set(photos.prefix(3).map(\.id))
    store.updateGridSelection(ids, currentID: photos[1].id)
    XCTAssertEqual(store.actionPhotos.count, 3)
    XCTAssertFalse(store.canExport)
    store.inspect(photos[1])
    XCTAssertEqual(store.actionPhotos.count, 1)
    XCTAssertEqual(store.batchSelection.ids.count, 3)
    store.navigate(by: 1)
    XCTAssertEqual(store.selectionID, photos[2].id)
    store.escape()
    XCTAssertEqual(store.viewMode, .contactSheet)
    XCTAssertEqual(store.batchSelection.ids, ids)
    await store.deleteSelection()
    XCTAssertEqual(store.photos.count, 1)
    XCTAssertEqual(store.undoCount, 1)
    store.dismissNotice()
    await store.restoreLastTrash()
    XCTAssertEqual(store.photos.count, 4)
    XCTAssertEqual(store.batchSelection.ids, ids)
    XCTAssertEqual(store.undoCount, 0)
    store.setFilter(.favorites)
    XCTAssertTrue(store.batchSelection.ids.isEmpty)
    XCTAssertFalse(store.canDelete)
    XCTAssertFalse(store.canExport)
  }

  func testRangeAnchorPersistsAcrossRepeatedShiftAndResetsAfterReload() {
    var anchor = SelectionRangeAnchor()
    XCTAssertEqual(anchor.range(to: 2, current: 1, count: 10), 1...2)
    XCTAssertEqual(anchor.range(to: 3, current: 2, count: 10), 1...3)
    XCTAssertEqual(anchor.range(to: 0, current: 3, count: 10), 0...1)
    anchor.set(9)
    anchor.reset()
    XCTAssertEqual(anchor.range(to: 1, current: 0, count: 3), 0...1)
    anchor.set(90)
    XCTAssertEqual(anchor.range(to: 1, current: 0, count: 3), 1...2)
    XCTAssertNil(anchor.range(to: 0, current: nil, count: 0))
  }

  @MainActor func testScopeChangesSelectFirstVisibleAndClearRemovesPreview() async throws {
    let (root, _) = try fixtures(3)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: UserDefaults(suiteName: "FrameScopeTest.\(UUID())")!)
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    XCTAssertNotNil(store.selectedPhoto)
    XCTAssertEqual(store.batchSelection.ids, [try XCTUnwrap(store.selectedPhoto?.id)])
    XCTAssertTrue(store.canDelete)
    XCTAssertTrue(store.canInspect)
    store.openViewer()
    XCTAssertEqual(store.viewMode, .inspect)
    store.escape()
    store.escape()
    store.select(try XCTUnwrap(store.selectedPhoto))
    store.toggleFavorite()
    store.setFilter(.favorites)
    XCTAssertEqual(store.visiblePhotos.count, 1)
    XCTAssertEqual(store.batchSelection.ids.count, 1)
    XCTAssertTrue(store.canExport)
    store.select(try XCTUnwrap(store.selectedPhoto))
    store.selectFolder("")
    XCTAssertEqual(store.batchSelection.ids.count, 1)
    XCTAssertTrue(store.canDelete)
    store.updateGridSelection([], currentID: store.selectionID)
    XCTAssertNil(store.selectedPhoto)
    XCTAssertNil(store.batchSelection.currentID)
    XCTAssertTrue(store.metadata.identity.isEmpty)
    XCTAssertFalse(store.canInspect)
    XCTAssertFalse(store.canDelete)
    XCTAssertFalse(store.canExport)
  }

  @MainActor func testInspectTrashPreservesSurvivingBatchAndLocksNavigation() async throws {
    let (root, _) = try fixtures(4)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: UserDefaults(suiteName: "FrameInspectTest.\(UUID())")!)
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    let photos = store.photos
    let ids = Set(photos.prefix(3).map(\.id))
    store.updateGridSelection(ids, currentID: photos[1].id)
    store.inspect(photos[1])
    let operation = Task { await store.deleteSelection() }
    await Task.yield()
    if store.isFileOperation {
      let current = store.selectionID
      store.navigate(by: 1)
      XCTAssertEqual(store.selectionID, current)
    }
    await operation.value
    XCTAssertEqual(store.batchSelection.ids, ids.subtracting([photos[1].id]))
    store.escape()
    XCTAssertEqual(store.actionPhotos.count, 2)
    await store.restoreLastTrash()
    XCTAssertEqual(store.photos.count, 4)
  }

  func testRestoreRefusesForeignReplacementInTrash() async throws {
    let (root, photos) = try fixtures(1)
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("TrashCopy")
    let result = await BatchTrash.move(photos, operation: { source in
      try FileManager.default.moveItem(at: source, to: trash)
      return trash
    })
    let retained = root.appendingPathComponent("OriginalRetained")
    try FileManager.default.moveItem(at: trash, to: retained)
    try Data("foreign".utf8).write(to: trash)
    let restore = BatchTrash.restore(result.successes)
    XCTAssertTrue(restore.restored.isEmpty)
    XCTAssertTrue(restore.failed.isEmpty)
    XCTAssertEqual(restore.errors.count, 1)
    XCTAssertEqual(try Data(contentsOf: trash), Data("foreign".utf8))
  }
}
