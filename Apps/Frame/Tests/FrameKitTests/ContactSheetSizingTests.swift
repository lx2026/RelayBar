import AppKit
import Composition
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import FrameKit

final class ContactSheetSizingTests: XCTestCase {
  func testSizesClampAndColumnsFollowAvailableWidth() {
    XCTAssertEqual(ContactSheetMetrics.normalizedWidth(.nan), 160)
    XCTAssertEqual(ContactSheetMetrics.normalizedWidth(.infinity), 160)
    XCTAssertEqual(ContactSheetMetrics.normalizedWidth(10), 100)
    XCTAssertEqual(ContactSheetMetrics.normalizedWidth(1_000), 360)
    let small = ContactSheetMetrics(preferredWidth: 100, viewportWidth: 600)
    let large = ContactSheetMetrics(preferredWidth: 360, viewportWidth: 600)
    XCTAssertEqual(small.columns, 5)
    XCTAssertEqual(large.columns, 1)
    XCTAssertEqual(small.visibleRows(in: 600), 5)
    XCTAssertEqual(large.visibleRows(in: 600), 1)
    XCTAssertEqual(large.visibleRows(in: .nan), 1)
    let narrow = ContactSheetMetrics(preferredWidth: 360, viewportWidth: 260)
    XCTAssertEqual(narrow.width, 204)
    XCTAssertEqual(narrow.height, 172)
    XCTAssertEqual(narrow.columns, 1)
    let compact = ContactSheetMetrics(preferredWidth: 160, viewportWidth: 330)
    XCTAssertEqual(compact.columns, 1)
    XCTAssertEqual(compact.width, 160)
    let wide = ContactSheetMetrics(preferredWidth: 200, viewportWidth: 1_020)
    XCTAssertEqual(wide.columns, 5)
    XCTAssertEqual(wide.width, 180)
    XCTAssertEqual(wide.wellHeight, 132)
    XCTAssertEqual(ContactSheetMetrics(preferredWidth: 320, viewportWidth: 330).columns, 1)
  }

  func testDecodeRequestsTrackSizeAndRemainBounded() {
    let small = ContactSheetMetrics(preferredWidth: 100, viewportWidth: 600)
    let large = ContactSheetMetrics(preferredWidth: 360, viewportWidth: 600)
    XCTAssertEqual(small.thumbnailPixels(scale: 2), 256)
    XCTAssertEqual(large.thumbnailPixels(scale: 2), 768)
    XCTAssertEqual(large.thumbnailPixels(scale: 3), 1_152)
    XCTAssertEqual(ContactSheetMetrics.previewPixels(width: 600, height: 400, scale: 2), 1_280)
    XCTAssertEqual(ContactSheetMetrics.previewPixels(width: 10_000, height: 8_000, scale: 3), 4_096)
    XCTAssertEqual(ContactSheetMetrics.previewPixels(width: .nan, height: .infinity, scale: 2), 640)
  }

  @MainActor func testPreferencePersistsWithoutChangingSelection() async throws {
    let suite = "FrameSizingTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameSizing-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("one.jpg"))
    try Data().write(to: root.appendingPathComponent("two.png"))
    let container = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("FrameSizingSettings-\(UUID())")
    defer { try? FileManager.default.removeItem(at: state) }
    let storage = state.appendingPathComponent("preferences.json")
    let store = LibraryStore(defaults: defaults, previews: FrameComposition(preferencesURL: storage))
    await store.start(modelContext: container.mainContext)
    await store.openRoot(root)
    let ids = Set(store.photos.map(\.id))
    let current = try XCTUnwrap(store.photos.last?.id)
    store.updateGridSelection(ids, currentID: current)
    await store.setThumbnailWidth(320)
    XCTAssertEqual(store.batchSelection.ids, ids)
    XCTAssertEqual(store.selectionID, current)
    XCTAssertEqual(store.thumbnailWidth, 320)
    XCTAssertNil(defaults.object(forKey: "contactSheetThumbnailWidth"))
    let reopened = LibraryStore(defaults: defaults, previews: FrameComposition(preferencesURL: storage))
    try await reopened.previews.start()
    XCTAssertEqual(reopened.thumbnailWidth, 320)
    await reopened.shutdown()
    await store.setThumbnailWidth(-1)
    XCTAssertEqual(store.thumbnailWidth, 100)
    await store.shutdown()
  }

  func testLargerPreviewActuallyDecodesMoreDetail() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FrameSizing-\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let context = try XCTUnwrap(CGContext(data: nil, width: 2_048, height: 1_024,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2_048, height: 1_024))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let repository = ImageRepository()
    let small = await repository.image(for: url, maxPixelSize: 256)
    let large = await repository.image(for: url, maxPixelSize: 1_280)
    XCTAssertEqual(small?.width, 256)
    XCTAssertEqual(large?.width, 1_280)
    XCTAssertEqual(large?.height, 640)
  }
}
