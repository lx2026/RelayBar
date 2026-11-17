import Foundation
import SwiftData
import XCTest
@testable import FrameKit

/// A catalog written before the change-marker models existed opens through the app's own code with every row intact.
@MainActor
final class CatalogUpgradeTests: XCTestCase {
  func testCatalogFromBeforeTheChangeMarkersKeepsItsRowsAndGainsTheNewModels() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FrameCatalogUpgrade-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("default.store")
    let rootID = UUID(), remoteID = UUID()
    let archived = "Archive/\(UUID().uuidString)/a.jpg"

    // The schema as it was: recent folders and favourites only.
    do {
      let previous = Schema([LibraryRootRecord.self, FavoriteRecord.self])
      let container = try ModelContainer(for: previous, configurations: ModelConfiguration(schema: previous, url: url))
      let context = container.mainContext
      context.insert(LibraryRootRecord(id: rootID, displayName: "Studio", bookmarkData: Data([1, 2, 3]),
                                       lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000)))
      context.insert(LibraryRootRecord(id: remoteID, displayName: "Photos", bookmarkData: Data([4])))
      context.insert(FavoriteRecord(rootID: rootID, relativePath: "glass-lagoon.png", isFavorite: true))
      context.insert(FavoriteRecord(rootID: rootID, relativePath: "Notes/api-notes.md", isFavorite: true))
      context.insert(FavoriteRecord(rootID: rootID, relativePath: "winter-fern.jpg", isFavorite: false))
      context.insert(FavoriteRecord(rootID: rootID, relativePath: archived, isFavorite: true))
      try context.save()
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    XCTAssertTrue(files.contains("default.store"))

    // Opened the way the app opens it.
    do {
      let container = try FrameCatalogStore.open(at: url)
      let context = container.mainContext
      let roots = try context.fetch(FetchDescriptor<LibraryRootRecord>()).sorted { $0.displayName > $1.displayName }
      XCTAssertEqual(roots.map(\.displayName), ["Studio", "Photos"])
      XCTAssertEqual(roots.first?.bookmarkData, Data([1, 2, 3]))
      XCTAssertEqual(roots.first?.lastOpenedAt, Date(timeIntervalSince1970: 1_700_000_000))
      let favorites = try context.fetch(FetchDescriptor<FavoriteRecord>())
      XCTAssertEqual(Set(favorites.filter(\.isFavorite).map(\.relativePath)), ["glass-lagoon.png", "Notes/api-notes.md", archived])
      XCTAssertEqual(favorites.count, 4)
      XCTAssertTrue(favorites.allSatisfy { $0.key == FavoriteRecord.makeKey(rootID: $0.rootID, relativePath: $0.relativePath) })
      XCTAssertTrue(try context.fetch(FetchDescriptor<OpenedFileRecord>()).isEmpty)
      context.insert(FolderBaselineRecord(rootID: rootID, folderPath: "", baseline: Date(timeIntervalSince1970: 1_800_000_000)))
      context.insert(OpenedFileRecord(rootID: rootID, relativePath: "notes.md", openedAt: Date(timeIntervalSince1970: 1_800_000_100)))
      try context.save()
    }

    // Everything is still there the next time.
    let container = try FrameCatalogStore.open(at: url)
    let context = container.mainContext
    XCTAssertEqual(try context.fetch(FetchDescriptor<FavoriteRecord>()).count, 4)
    XCTAssertEqual(try context.fetch(FetchDescriptor<LibraryRootRecord>()).count, 2)
    XCTAssertEqual(try context.fetch(FetchDescriptor<FolderBaselineRecord>()).first?.baseline, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(try context.fetch(FetchDescriptor<OpenedFileRecord>()).first?.key, FavoriteRecord.makeKey(rootID: rootID, relativePath: "notes.md"))
  }
}
