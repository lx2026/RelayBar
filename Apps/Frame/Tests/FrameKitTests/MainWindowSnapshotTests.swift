import AppKit
import CompositionFixtures
import SwiftData
import SwiftUI
import XCTest
@testable import Frame
@testable import FrameKit

@MainActor
final class MainWindowSnapshotTests: XCTestCase {
  private func openLibrary() async throws -> (LibraryStore, ModelContainer) {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = temporary.appendingPathComponent("Field notes")
    addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
    for name in ["Archive", "Studies", ".drafts"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try PNGFixture.compressed.data().write(to: root.appendingPathComponent("Study.png"))
    for name in ["Index.txt", ".notes.txt"] {
      try Data("Field notes".utf8).write(to: root.appendingPathComponent(name))
    }
    for (index, name) in ["Archive", "Studies", "Index.txt", "Study.png"].enumerated() {
      let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
      try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: root.appendingPathComponent(name).path)
    }
    let model = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let id = UUID()
    let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    model.mainContext.insert(LibraryRootRecord(id: id, displayName: root.lastPathComponent, bookmarkData: bookmark))
    model.mainContext.insert(FavoriteRecord(rootID: id, relativePath: "Study.png", isFavorite: true))
    try model.mainContext.save()
    let suite = "FrameBrowsing.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "localIncludesSubfolders")
    let store = LibraryStore(defaults: defaults)
    await store.start(modelContext: model.mainContext)
    addTeardownBlock { await store.shutdown() }
    store.setViewMode(.contactSheet)
    return (store, model)
  }

  func testSavedFavoriteLoadsAsAPinAndIconsUseDefaultOrder() async throws {
    let (store, catalog) = try await openLibrary()
    defer { withExtendedLifetime(catalog) {} }
    XCTAssertEqual(store.gridFolders.map(\.name), ["Studies", "Archive"])
    XCTAssertEqual(store.visiblePhotos.map(\.name), ["Study.png", "Index.txt"])
    store.setFilter(.favorites)
    XCTAssertEqual(store.visiblePhotos.map(\.name), ["Study.png"])
  }

  func testMainWindowSnapshots() async throws {
    guard let path = ProcessInfo.processInfo.environment["FRAME_SNAPSHOT_DIR"], !path.isEmpty else {
      throw XCTSkip("Set FRAME_SNAPSHOT_DIR to capture the main window.")
    }
    QuietWindow.prepareTestProcess()
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let (store, catalog) = try await openLibrary()
    let host = NSHostingView(rootView: FrameRootView(store: store, modelContainer: catalog))
    let window = QuietWindow(size: NSSize(width: 1280, height: 740), styleMask: [.titled, .fullSizeContentView])
    window.contentView = host
    window.orderInOffscreen()
    defer { window.orderOut(nil); window.contentView = nil }

    func record(_ state: String) async throws {
      for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        window.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 2_000)
        try data.write(to: directory.appendingPathComponent("frame-\(state)-\(suffix).png"))
      }
    }
    XCTAssertEqual(store.hiddenCount(in: ""), 2)
    try await record("folder")
    func outline(in view: NSView) -> NSOutlineView? {
      if let tree = view as? NSOutlineView { return tree }
      for child in view.subviews {
        if let tree = outline(in: child) { return tree }
      }
      return nil
    }
    let tree = try XCTUnwrap(outline(in: host))
    func sidebarFilesAndFolders() -> [String] {
      (0..<tree.numberOfRows).compactMap {
        (tree.view(atColumn: 0, row: $0, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue
      }
    }
    XCTAssertEqual(sidebarFilesAndFolders(), ["Field notes", "Studies", "Archive", "Study.png", "Index.txt"])
    let lastRow = try XCTUnwrap(tree.view(atColumn: 0, row: tree.numberOfRows - 1, makeIfNecessary: false) as? NSStackView)
    XCTAssertEqual(lastRow.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }, ["2 hidden items"])
    let show = try XCTUnwrap(lastRow.arrangedSubviews.compactMap { $0 as? NSButton }.first)
    XCTAssertEqual(show.title, "Show")
    show.performClick(nil)
    XCTAssertEqual(store.hiddenCount(in: ""), 0)
    try await record("folder-shown")
    XCTAssertEqual(sidebarFilesAndFolders(), ["Field notes", ".drafts", "Studies", "Archive", ".notes.txt", "Study.png", "Index.txt"])
    let photo = try XCTUnwrap(store.visiblePhotos.first { $0.name == "Study.png" })
    store.showFile(photo)
    for _ in 0..<200 where store.metadata.negativePrompt == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(store.metadata.prompt, PNGFixture.compressed.prompt)
    XCTAssertEqual(store.metadata.negativePrompt, "Haze")
    XCTAssertEqual(store.metadata.aiGeneration.map(\.label), ["Seed", "Steps"])
    XCTAssertEqual(store.metadata.aiGeneration.map(\.value), ["42", "20"])
    try await record("details")
  }
}
