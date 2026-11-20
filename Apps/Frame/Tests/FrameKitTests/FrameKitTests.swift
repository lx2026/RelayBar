import Foundation
import XCTest

@testable import FrameKit

final class FrameKitTests: XCTestCase {
  func testScannerIncludesOnlyJPEGAndPNGAndBuildsFolderCounts() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("jpeg".utf8).write(to: root.appendingPathComponent("one.JPG"))
    try Data("png".utf8).write(to: nested.appendingPathComponent("two.png"))
    try Data("ignored".utf8).write(to: nested.appendingPathComponent("notes.txt"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.jpg"))

    let rootID = UUID()
    let result = try FileScanner.scan(rootURL: root, rootID: rootID)

    XCTAssertEqual(result.photos.map(\.relativePath), [".hidden.jpg", "nested/two.png", "one.JPG"])
    XCTAssertEqual(result.rootFolder.photoCount, 3)
    XCTAssertEqual(result.rootFolder.children.count, 1)
    XCTAssertEqual(result.rootFolder.children.first?.relativePath, "nested")
    XCTAssertEqual(result.rootFolder.children.first?.photoCount, 1)
  }

  func testPNGParametersBecomeReadableAIMetadata() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("generated.png")
    let parameters =
      "A quiet orange moon over dunes\nNegative prompt: text, watermark\nSteps: 28, Sampler: Euler, CFG scale: 3.5, Seed: 42, Model: flux-dev"
    try pngData(textKey: "parameters", value: parameters).write(to: fileURL)

    let photo = PhotoItem(
      id: "photo",
      rootID: UUID(),
      url: fileURL,
      relativePath: "generated.png",
      folderRelativePath: "",
      name: "generated.png",
      format: .png,
      fileSize: Int64((try Data(contentsOf: fileURL)).count),
      createdAt: nil,
      modifiedAt: nil,
      fileIdentifier: nil
    )

    let metadata = await ImageMetadataReader.read(photo: photo)

    XCTAssertEqual(metadata.prompt, "A quiet orange moon over dunes")
    XCTAssertEqual(metadata.negativePrompt, "text, watermark")
    XCTAssertTrue(metadata.aiGeneration.contains(MetadataRow(label: "Steps", value: "28")))
    XCTAssertTrue(metadata.aiGeneration.contains(MetadataRow(label: "Seed", value: "42")))
    XCTAssertEqual(
      metadata.embedded.first(where: { $0.label == "PNG.parameters" })?.value, parameters)
  }

  func testExactCopyExporterCompletelyReplacesDestinationBytes() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.png")
    let destination = root.appendingPathComponent("destination.png")
    let sourceBytes = Data((0..<4_096).map { UInt8($0 % 251) })
    let previousDestinationBytes = Data("old pixels and old metadata".utf8)
    try sourceBytes.write(to: source)
    try previousDestinationBytes.write(to: destination)

    try ExactCopyExporter.export(source: source, destination: destination)

    XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
    XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: {
        $0.contains("frame-export")
      }))
  }

  func testExactCopyExporterRejectsSourceAsDestination() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.jpg")
    try Data("unchanged".utf8).write(to: source)

    XCTAssertThrowsError(try ExactCopyExporter.export(source: source, destination: source)) {
      error in
      guard case ExportError.sourceAndDestinationMatch = error else {
        return XCTFail("Expected sourceAndDestinationMatch, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: source), Data("unchanged".utf8))
  }

  func testPhotoQueryCombinesRecursiveFolderScopeAndFavorites() {
    let rootID = UUID()
    let photos = [
      photo(id: "root", rootID: rootID, path: "root.jpg", folder: ""),
      photo(id: "botanical", rootID: rootID, path: "Botanical/one.png", folder: "Botanical"),
      photo(
        id: "nested", rootID: rootID, path: "Botanical/Night/two.png", folder: "Botanical/Night"),
      photo(
        id: "architecture", rootID: rootID, path: "Architecture/three.jpg", folder: "Architecture"),
    ]

    let allBotanical = PhotoQuery.visiblePhotos(
      in: photos,
      folderRelativePath: "Botanical",
      filter: .all,
      favorites: ["nested"]
    )
    XCTAssertEqual(allBotanical.map(\.id), ["botanical", "nested"])

    let favoriteBotanical = PhotoQuery.visiblePhotos(
      in: photos,
      folderRelativePath: "Botanical",
      filter: .favorites,
      favorites: ["nested", "architecture"]
    )
    XCTAssertEqual(favoriteBotanical.map(\.id), ["nested"])
  }

  func testFiveThousandFileScanAndFilterBudgets() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for index in 0..<5_000 {
      let file = nested.appendingPathComponent(
        String(format: "%05d.%@", index, index.isMultiple(of: 2) ? "jpg" : "png"))
      FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: nil)
    }

    let rootID = UUID()
    let scanStart = ContinuousClock.now
    let result = try FileScanner.scan(rootURL: root, rootID: rootID)
    let scanDuration = scanStart.duration(to: .now)

    let favoriteIDs = Set(result.photos.prefix(1_000).map(\.id))
    let filterStart = ContinuousClock.now
    let filtered = PhotoQuery.visiblePhotos(
      in: result.photos,
      folderRelativePath: "library",
      filter: .favorites,
      favorites: favoriteIDs
    )
    let filterDuration = filterStart.duration(to: .now)

    print("PERFORMANCE scan-5000=\(scanDuration) filter-5000=\(filterDuration)")
    XCTAssertEqual(result.photos.count, 5_000)
    XCTAssertEqual(filtered.count, 1_000)
    XCTAssertLessThan(scanDuration, .seconds(1.5))
    XCTAssertLessThan(filterDuration, .milliseconds(100))
  }

  func testStageAndTwelveThumbnailColdLoadBudget() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2+XQAAAAASUVORK5CYII="
    )!
    let urls = try (0..<13).map { index -> URL in
      let url = root.appendingPathComponent("\(index).png")
      try png.write(to: url)
      return url
    }

    let images = ImageRepository()
    let coldStart = ContinuousClock.now
    await withTaskGroup(of: CGImage?.self) { group in
      group.addTask { await images.image(for: urls[0], maxPixelSize: 1_800) }
      for url in urls.dropFirst() {
        group.addTask { await images.image(for: url, maxPixelSize: 240) }
      }
      for await image in group {
        XCTAssertNotNil(image)
      }
    }
    let coldDuration = coldStart.duration(to: .now)

    let cachedStart = ContinuousClock.now
    let cached = await images.image(for: urls[1], maxPixelSize: 240)
    let cachedDuration = cachedStart.duration(to: .now)

    print("PERFORMANCE stage-plus-12=\(coldDuration) cached-adjacent=\(cachedDuration)")
    XCTAssertNotNil(cached)
    XCTAssertLessThan(coldDuration, .seconds(1.5))
    XCTAssertLessThan(cachedDuration, .milliseconds(100))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("FrameTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func photo(id: String, rootID: UUID, path: String, folder: String) -> PhotoItem {
    PhotoItem(
      id: id,
      rootID: rootID,
      url: URL(fileURLWithPath: "/tmp/\(path)"),
      relativePath: path,
      folderRelativePath: folder,
      name: (path as NSString).lastPathComponent,
      format: path.hasSuffix(".png") ? .png : .jpeg,
      fileSize: 1,
      createdAt: nil,
      modifiedAt: nil,
      fileIdentifier: nil
    )
  }

  private func pngData(textKey: String, value: String) -> Data {
    var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
    var payload = Data(textKey.data(using: .isoLatin1)!)
    payload.append(0)
    payload.append(value.data(using: .isoLatin1)!)
    appendChunk(type: "tEXt", payload: payload, to: &data)
    appendChunk(type: "IEND", payload: Data(), to: &data)
    return data
  }

  private func appendChunk(type: String, payload: Data, to data: inout Data) {
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(type.data(using: .ascii)!)
    data.append(payload)
    data.append(contentsOf: [0, 0, 0, 0])  // PNGTextReader does not need CRC validation.
  }
}
