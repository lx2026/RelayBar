import AppKit
import AVFoundation
import SwiftData
import XCTest
@testable import FrameKit

final class RedesignTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
  }
  private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRedesign-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func copyFixture(_ name: String, to root: URL, as target: String? = nil) throws -> URL {
    let url = root.appendingPathComponent(target ?? name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture(name), to: url)
    return url
  }
  private func item(_ name: String) throws -> PhotoItem {
    let result = try FileScanner.scan(rootURL: fixture(name).deletingLastPathComponent(), rootID: UUID())
    return try XCTUnwrap(result.photos.first { $0.name == name })
  }
  @MainActor private func catalog() throws -> ModelContainer {
    try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
  }
  @MainActor private func store(scanner: LibraryStore.Scanner? = nil) -> LibraryStore {
    let defaults = UserDefaults(suiteName: "FrameTests.\(UUID())")!
    if let scanner { return LibraryStore(defaults: defaults, scanner: scanner) }
    return LibraryStore(defaults: defaults)
  }
  @MainActor private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
  }

  func testMixedExtensionsAndRecursiveCounts() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try copyFixture("landscape.mp4", to: root, as: "root.MP4")
    _ = try copyFixture("portrait.mov", to: root, as: "Child/portrait.MoV")
    _ = try copyFixture("short.m4v", to: root, as: "Child/Deep/short.M4V")
    try Data().write(to: root.appendingPathComponent("still.JpEg"))
    try Data().write(to: root.appendingPathComponent("Child/still.PNG"))
    try Data().write(to: root.appendingPathComponent("ignored.avi"))
    let result = try FileScanner.scan(rootURL: root, rootID: UUID())
    XCTAssertEqual(result.photos.count, 5)
    XCTAssertEqual(result.rootFolder.children.first?.photoCount, 3)
    XCTAssertEqual(result.photos.filter { $0.format.isVideo }.count, 3)
  }

  func testRealVideoMetadataPostersOrientationAndShortClip() async throws {
    for (name, width, height, audio) in [
      ("landscape.mp4", 160, 90, "AAC"), ("portrait.mov", 90, 160, "AAC"), ("short.m4v", 160, 90, "None")
    ] {
      let photo = try item(name)
      let info = await VideoMetadataReader().info(for: photo)
      XCTAssertTrue(info.playable, name)
      XCTAssertEqual(info.width, width, name)
      XCTAssertEqual(info.height, height, name)
      XCTAssertEqual(info.audio, audio, name)
      XCTAssertEqual(info.codec, "H.264")
      XCTAssertGreaterThan(info.duration ?? 0, 0)
      let poster = await ImageRepository().image(for: photo.url, maxPixelSize: 240)
      XCTAssertNotNil(poster, name)
      XCTAssertEqual(Double(poster!.width) / Double(poster!.height), Double(width) / Double(height), accuracy: 0.02)
      let metadata = await ImageMetadataReader.read(photo: photo)
      XCTAssertTrue(metadata.identity.contains { $0.label == "Duration" })
      XCTAssertTrue(metadata.identity.contains { $0.label == "Audio" && $0.value == audio })
    }
  }

  func testCorruptVideoCompletesWithIdentityAndNoPoster() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("not a movie".utf8).write(to: root.appendingPathComponent("broken.mp4"))
    let photo = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: UUID()).photos.first)
    let info = await VideoMetadataReader().info(for: photo)
    XCTAssertFalse(info.playable)
    let poster = await ImageRepository().image(for: photo.url, maxPixelSize: 240)
    XCTAssertNil(poster)
    let metadata = await ImageMetadataReader.read(photo: photo)
    XCTAssertTrue(metadata.identity.contains { $0.label == "Type" && $0.value == "MP4" })
  }

  @MainActor func testPlaybackStartsPausedAndSelectionFilterAndGridReleaseIt() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try copyFixture("landscape.mp4", to: root)
    _ = try copyFixture("portrait.mov", to: root)
    let container = try catalog()
    let store = store()
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    store.select(try XCTUnwrap(store.selectedPhoto))
    store.inspect(try XCTUnwrap(store.selectedPhoto))
    let ready = await eventually { store.playback.player != nil }
    XCTAssertTrue(ready)
    let player = try XCTUnwrap(store.playback.player)
    XCTAssertEqual(player.rate, 0)
    store.togglePlayback()
    let playing = await eventually { player.rate != 0 }
    XCTAssertTrue(playing)
    store.openViewer()
    XCTAssertTrue(store.playback.player === player, "Opening an already-open viewer must not rebuild the player")
    XCTAssertTrue(store.playback.player === player)
    store.navigate(by: 1)
    XCTAssertEqual(player.rate, 0)
    XCTAssertNil(player.currentItem)
    let secondReady = await eventually { store.playback.player != nil }
    XCTAssertTrue(secondReady)
    store.toggleContactSheet()
    XCTAssertNil(store.playback.player)
    store.togglePlayback()
    XCTAssertNil(store.playback.player)
    store.toggleContactSheet()
    store.setFilter(.favorites)
    XCTAssertNil(store.selectedPhoto)
    XCTAssertNil(store.playback.player)
    XCTAssertFalse(store.canExport)
  }

  @MainActor func testScopesFavoritesRecentsAndRelocationRetainIdentity() async throws {
    let root = try temporaryRoot()
    let relocated = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: relocated) }
    _ = try copyFixture("landscape.mp4", to: root, as: "root.mp4")
    _ = try copyFixture("short.m4v", to: root, as: "Child/short.m4v")
    _ = try copyFixture("short.m4v", to: relocated, as: "Child/short.m4v")
    let container = try catalog()
    let store = store()
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    let id = try XCTUnwrap(store.activeRootID)
    store.setViewMode(.contactSheet)
    let loaded = await eventually { store.photos.count == 2 && !store.isScanning }
    XCTAssertTrue(loaded)
    XCTAssertEqual(store.folderChoices.map(\.relativePath), ["Child"], "Root files plus one child need a scope menu")
    store.selectFolder("Child")
    let selectedID = try XCTUnwrap(store.selectionID)
    store.toggleFavorite()
    store.setFilter(.favorites)
    XCTAssertEqual(store.visiblePhotos.count, 1)
    await store.openRoot(relocated, replacingRootID: id)
    XCTAssertEqual(store.activeRootID, id)
    XCTAssertEqual(store.selectionID, selectedID)
    XCTAssertTrue(store.favorites.contains(selectedID))
    XCTAssertEqual(store.filter, .all)
    XCTAssertEqual(store.selectedFolderPath, "")
    XCTAssertTrue(store.folderChoices.isEmpty, "Equivalent scope results should not duplicate All files")
    let reopened = self.store()
    await reopened.start(modelContext: container.mainContext)
    XCTAssertEqual(reopened.activeRootID, id)
    XCTAssertTrue(reopened.favorites.contains(selectedID))
    store.removeRecent(id)
    XCTAssertTrue(store.recentFolders.isEmpty)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<FavoriteRecord>()).count, 1)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<LibraryRootRecord>()).count, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relocated.path), ["Child"])
  }

  @MainActor func testStaleScanCannotOverwriteNewRootOrMetadata() async throws {
    let slow = try temporaryRoot()
    let fast = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: slow); try? FileManager.default.removeItem(at: fast) }
    _ = try copyFixture("landscape.mp4", to: slow)
    _ = try copyFixture("portrait.mov", to: fast)
    let container = try catalog()
    let store = store { url, id in
      let value = try FileScanner.scan(rootURL: url, rootID: id)
      if url.path == slow.path { try? await Task.sleep(for: .milliseconds(200)) }
      return value // Deliberately ignore cancellation to exercise generation protection.
    }
    await store.start(modelContext: container.mainContext)
    await store.openRoot(slow)
    store.setViewMode(.contactSheet)
    let scanning = await eventually { store.isScanning }
    XCTAssertTrue(scanning)
    await store.openRoot(fast)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(store.rootURL?.path, fast.path)
    XCTAssertEqual(store.selectedPhoto?.name, "portrait.mov")
    let metadataReady = await eventually { store.metadata.identity.contains { $0.label == "Dimensions" } }
    XCTAssertTrue(metadataReady)
    XCTAssertTrue(store.metadata.identity.contains { $0.value == "90 × 160" })
  }

  @MainActor func testUnavailableLastBookmarkOffersRecoveryAndMissingSelectionDisablesActions() async throws {
    let container = try catalog()
    let id = UUID()
    container.mainContext.insert(LibraryRootRecord(id: id, displayName: "Offline archive", bookmarkData: Data()))
    let store = store()
    await store.start(modelContext: container.mainContext)
    XCTAssertEqual(store.rootName, "Offline archive")
    XCTAssertEqual(store.activeRootID, id)
    XCTAssertTrue(store.rootUnavailable)
    XCTAssertFalse(store.hasAvailableSelection)
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try copyFixture("short.m4v", to: root)
    await store.openRoot(root, replacingRootID: id)
    XCTAssertEqual(store.activeRootID, id)
    XCTAssertFalse(store.rootUnavailable)
    try FileManager.default.removeItem(at: url)
    store.validateSourceAvailability()
    XCTAssertTrue(store.selectionMissing)
    XCTAssertFalse(store.hasAvailableSelection)
    XCTAssertFalse(store.canExport)
    XCTAssertNil(store.playback.player)
    XCTAssertTrue(store.metadata.identity.isEmpty)
  }

  @MainActor func testRecentDisplayCapDoesNotDiscardRecords() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let container = try catalog()
    let store = store()
    await store.start(modelContext: container.mainContext)
    for index in 0..<10 {
      let child = root.appendingPathComponent("\(index)")
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      await store.openRoot(child)
    }
    XCTAssertEqual(store.recentFolders.count, 8)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<LibraryRootRecord>()).count, 10)
    await store.openRoot(root.appendingPathComponent("9"))
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<LibraryRootRecord>()).count, 10)
  }

  @MainActor func testTrashUndoSurvivesNoticeDismissAndProtectsCollision() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try copyFixture("short.m4v", to: root)
    let original = try Data(contentsOf: url)
    let container = try catalog()
    let store = store()
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    store.select(try XCTUnwrap(store.selectedPhoto))
    await store.deleteSelection()
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(store.canUndoTrash)
    store.dismissNotice()
    try Data("occupied".utf8).write(to: url)
    await store.restoreLastTrash()
    XCTAssertEqual(try Data(contentsOf: url), Data("occupied".utf8))
    XCTAssertTrue(store.canUndoTrash)
    try FileManager.default.removeItem(at: url)
    store.errorMessage = nil
    await store.restoreLastTrash()
    XCTAssertNil(store.errorMessage)
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertFalse(store.canUndoTrash)
    let restored = await eventually { store.selectedPhoto != nil && !store.isScanning }
    XCTAssertTrue(restored)
  }

  @MainActor func testAsyncVideoExportReplacesMetadataAndPreservesOriginal() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try copyFixture("landscape.mp4", to: root)
    let destination = try copyFixture("short.m4v", to: root, as: "destination.mp4")
    let original = try Data(contentsOf: source)
    let photo = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: UUID()).photos.first { $0.name == source.lastPathComponent })
    let store = store()
    await store.export(photo, to: destination)
    XCTAssertNil(store.errorMessage)
    XCTAssertFalse(store.isExporting)
    XCTAssertEqual(try Data(contentsOf: destination), original)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testSameFileAliasesCannotOverwriteSource() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try copyFixture("short.m4v", to: root)
    let link = root.appendingPathComponent("link.m4v")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    XCTAssertThrowsError(try ExactCopyExporter.export(source: source, destination: link))
    let hardlink = root.appendingPathComponent("hardlink.m4v")
    try FileManager.default.linkItem(at: source, to: hardlink)
    XCTAssertThrowsError(try ExactCopyExporter.export(source: source, destination: hardlink))
  }

  @MainActor func testAdaptivePaletteContrastInBothAppearances() {
    func luminance(_ color: NSColor, appearance: NSAppearance) -> Double {
      var result = 0.0
      appearance.performAsCurrentDrawingAppearance {
        let rgb = color.usingColorSpace(.sRGB)!
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
          $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        result = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
      }
      return result
    }
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let appearance = NSAppearance(named: name)!
      for surface in [FrameColors.paper, FrameColors.panel, FrameColors.stage, FrameColors.selected] {
        for foreground in [FrameColors.ink, FrameColors.muted, FrameColors.amber] {
          let a = luminance(surface, appearance: appearance)
          let b = luminance(foreground, appearance: appearance)
          XCTAssertGreaterThanOrEqual((max(a,b) + 0.05) / (min(a,b) + 0.05), 4.5, "\(name)")
        }
      }
      let a = luminance(FrameColors.button, appearance: appearance)
      let b = luminance(FrameColors.buttonText, appearance: appearance)
      XCTAssertGreaterThanOrEqual((max(a,b) + 0.05) / (min(a,b) + 0.05), 4.5)
    }
  }
}
