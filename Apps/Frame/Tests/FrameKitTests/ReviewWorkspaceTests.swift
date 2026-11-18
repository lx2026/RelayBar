import BridgeProtocol
import Foundation
import SwiftData
import XCTest
@testable import FrameKit

final class ReviewWorkspaceTests: XCTestCase {
  @MainActor private func withStore(_ body: (LibraryStore) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameReview-\(UUID())")
    let defaults = UserDefaults(suiteName: "FrameReview.\(UUID())")!
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Child"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a.png", "b.png", "Child/c.jpg"] {
      try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
    }
    try Data(#"{"prompt":"A test image","seed":42}"#.utf8).write(to: root.appendingPathComponent("a.json"))
    let container = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: defaults)
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    store.setFileTypeFilter(.images)
    store.setViewMode(.contactSheet)
    for _ in 0..<200 {
      if store.visiblePhotos.count == 3 && !store.isScanning { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    try await body(store)
    await store.shutdown()
  }

  @MainActor func testMixedBatchFavoritesAddAllThenRemoveAll() async throws {
    try await withStore { store in
      let first = try XCTUnwrap(store.selectedPhoto)
      store.toggleFavorite()
      XCTAssertTrue(store.isFavorite(first))
      let targets = Set(store.visiblePhotos.map(\.id))
      store.updateGridSelection(targets, currentID: first.id)
      XCTAssertFalse(store.allActionPhotosFavorite)
      XCTAssertEqual(store.selectedMemberCount, 4)
      store.toggleFavorite()
      XCTAssertTrue(store.allActionPhotosFavorite)
      XCTAssertEqual(store.favorites.count, 3)
      store.toggleFavorite()
      XCTAssertTrue(store.favorites.isEmpty)
      XCTAssertEqual(store.batchSelection.ids, targets)
    }
  }
  @MainActor func testFavoriteAdvancesWhilePreservingCheckedDeletionTargets() async throws {
    try await withStore { store in
      let photos = store.visiblePhotos
      store.toggleSelectMode()
      store.toggleCurrentSelection()
      store.select(photos[1])
      store.toggleFavorite()
      XCTAssertTrue(store.isFavorite(photos[1]))
      XCTAssertFalse(store.isFavorite(photos[0]))
      XCTAssertEqual(store.selectionID, photos[2].id)
      XCTAssertEqual(store.batchSelection.ids, [photos[0].id])
      store.openViewer()
      store.toggleFavorite()
      XCTAssertTrue(store.isFavorite(photos[2]))
      XCTAssertEqual(store.selectionID, photos[0].id)
      XCTAssertEqual(store.viewMode, .inspect)
      XCTAssertEqual(store.batchSelection.ids, [photos[0].id])
    }
  }
  @MainActor func testFavoriteAdvancesInOldOrderWhenFilterRemovesCurrent() async throws {
    try await withStore { store in
      store.setFilter(.notFavorited)
      let photos = store.visiblePhotos
      store.select(photos[1])
      store.toggleFavorite()
      XCTAssertEqual(store.selectionID, photos[2].id)
      XCTAssertEqual(store.visiblePhotos.map(\.id), [photos[0].id, photos[2].id])
      store.toggleFavorite()
      XCTAssertEqual(store.selectionID, photos[0].id)
      store.toggleFavorite()
      XCTAssertTrue(store.visiblePhotos.isEmpty)
      XCTAssertNil(store.selectionID)
    }
  }

  @MainActor func testDeselectActiveChoosesSurvivorAndHiddenIDsAreRejected() async throws {
    try await withStore { store in
      let photos = store.visiblePhotos
      store.updateGridSelection([photos[0].id, photos[1].id], currentID: photos[0].id)
      store.updateGridSelection([photos[1].id], currentID: photos[0].id)
      XCTAssertEqual(store.selectionID, photos[1].id)
      store.selectFolder("Child")
      let child = try XCTUnwrap(store.selectedPhoto)
      XCTAssertEqual(store.batchSelection.ids, [child.id])
      store.updateGridSelection([photos[0].id], currentID: photos[0].id)
      XCTAssertTrue(store.batchSelection.ids.isEmpty)
      XCTAssertNil(store.selectedPhoto)
      XCTAssertFalse(store.canExport)
    }
  }

  @MainActor func testOpenChooserDisablesLocalActionsAndDoesNotLoseLocalSelection() async throws {
    try await withStore { store in
      let selected = store.selectionID
      store.presentOpenChooser()
      XCTAssertFalse(store.canDelete)
      XCTAssertFalse(store.canArchive)
      XCTAssertFalse(store.canExport)
      XCTAssertFalse(store.hasAvailableSelection)
      store.toggleFavorite()
      XCTAssertTrue(store.favorites.isEmpty)
      store.showsOpenChooser = false
      XCTAssertEqual(store.selectionID, selected)
      XCTAssertTrue(store.canExport)
    }
  }
  @MainActor func testInverseFavoriteFilterUsesCurrentFolderScope() async throws {
    try await withStore { store in
      let first = try XCTUnwrap(store.selectedPhoto)
      store.toggleFavorite()
      store.setFilter(.notFavorited)
      XCTAssertEqual(store.visiblePhotos.count, 2)
      XCTAssertFalse(store.visiblePhotos.contains { $0.id == first.id })
      store.selectFolder("Child")
      XCTAssertEqual(store.visiblePhotos.map(\.name), ["c.jpg"])
      store.toggleFavorite()
      XCTAssertTrue(store.visiblePhotos.isEmpty)
    }
  }

  @MainActor func testCatalogFailureClearsRevokedHistoryWithoutChangingLocalScope() async throws {
    let loader = CatalogSequence()
    let store = makeRemoteStore(remoteCatalogLoader: { try await loader.next() })
    await store.refreshRemoteLocations()
    XCTAssertEqual(store.remoteLocations.count, 1)
    XCTAssertNil(store.remoteCatalogError)
    await store.refreshRemoteLocations()
    XCTAssertTrue(store.remoteLocations.isEmpty)
    XCTAssertEqual(store.remoteCatalogError, "Access revoked")
    XCTAssertNil(store.activeRootID)
    XCTAssertFalse(store.isLoadingRemoteLocations)
    await store.refreshRemoteLocations()
    XCTAssertEqual(store.remoteLocations.count, 1)
    XCTAssertNil(store.remoteCatalogError)
  }

  func testJSONGenerationIsSourceSpecificAndDoesNotInterpretNestedWorkflows() {
    let summary = SidecarSummary(text: #"{"prompt":"A coastal photo","negative_prompt":"blur","seed":42,"steps":20,"model":"test","workflow":{"prompt":"not the summary"}}"#)
    XCTAssertEqual(summary.prompt, "A coastal photo")
    XCTAssertEqual(summary.negativePrompt, "blur")
    XCTAssertEqual(summary.rows.first { $0.label == "Seed" }?.value, "42")
    XCTAssertTrue(summary.hasGeneration)
    let nested = SidecarSummary(text: #"{"prompt":{"node":12},"workflow":{"seed":42}}"#)
    XCTAssertNil(nested.prompt)
    XCTAssertFalse(nested.hasGeneration)
    XCTAssertFalse(SidecarSummary(text: "Cannot preview JSON").hasGeneration)
    XCTAssertFalse(SidecarSummary(text: nil).hasGeneration)
  }
}

private actor CatalogSequence {
  var call = 0
  func next() throws -> BridgeResponse {
    call += 1
    if call == 2 { throw BridgeError("Access revoked") }
    let source = BridgeSource(id: String(repeating: "a", count: 64), name: "Test host")
    var response = BridgeResponse()
    response.locations = [BridgeLocation(id: "test", source: source, path: "/photos")]
    return response
  }
}
