import BridgeProtocol
import Foundation
import XCTest
@testable import FrameKit

final class RemotePreviewTests: XCTestCase {
  let source = BridgeSource(id: String(repeating: "a", count: 64), name: "Fixture")
  private func cache() throws -> RemotePreviewCache {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FramePreviewTests-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return RemotePreviewCache(root: root, limit: 20_000)
  }
  func testPreviewAndMetadataReuseWithinTheSameSessionWithoutFetchingOriginal() async throws {
    let fixture = PreviewFixture(), cache = try cache()
    let first = RelayRemoteClient(transport: { try await fixture.send($0) }, previewCache: cache)
    let listed = try await first.list(source: source, path: "/photos")
    let photo = try XCTUnwrap(listed.photos.first)
    let preview = try await first.preview(photo, pixels: 400)
    XCTAssertEqual(preview.metadata?["Dimensions"], "3000 × 2000")
    XCTAssertEqual(preview.sidecar, "{\"prompt\":\"fixture\"}")
    _ = try await first.preview(photo, pixels: 400)
    let firstCounts = await fixture.counts
    XCTAssertEqual(firstCounts["preview"], 1)
    let second = RelayRemoteClient(transport: { try await fixture.send($0) }, previewCache: cache)
    let secondList = try await second.list(source: source, path: "/photos")
    let secondPhoto = try XCTUnwrap(secondList.photos.first)
    let reused = try await second.preview(secondPhoto, pixels: 400)
    XCTAssertEqual(reused.image, preview.image)
    let counts = await fixture.counts, transfers = await fixture.imageTransfers
    XCTAssertNil(counts["fetch"])
    XCTAssertNil(counts["rememberOpen"])
    XCTAssertEqual(transfers, 1, "New client validates a cached fingerprint without transferring image again")
  }
  func testNewCacheDoesNotReadPreviousSessionAndClearRemovesFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FramePreviewTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = RemotePreviewCache(root: root)
    var value = BridgeAssetResult(); value.fingerprint = "one"; value.image = Data([1, 2, 3])
    try await first.write(value, key: "photo")
    let hit = await first.read("photo")
    XCTAssertNotNil(hit)
    let nextSession = RemotePreviewCache(root: root)
    let miss = await nextSession.read("photo")
    XCTAssertNil(miss)
    await first.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
  func testChangedRemoteFileInvalidatesDiskPreview() async throws {
    let fixture = PreviewFixture(), cache = try cache()
    let client = RelayRemoteClient(transport: { try await fixture.send($0) }, previewCache: cache)
    let firstList = try await client.list(source: source, path: "/photos")
    let a = try XCTUnwrap(firstList.photos.first)
    _ = try await client.preview(a, pixels: 2048)
    await fixture.change()
    let secondList = try await client.list(source: source, path: "/photos")
    let b = try XCTUnwrap(secondList.photos.first)
    let result = try await client.preview(b, pixels: 2048)
    XCTAssertEqual(result.fingerprint, "version-2")
    let transfers = await fixture.imageTransfers
    XCTAssertEqual(transfers, 2)
  }
  func testMissingPreviewDependencyDoesNotFallBackToOriginal() async throws {
    let fixture = PreviewFixture(failure: "Install Pillow on this host.")
    let client = RelayRemoteClient(transport: { try await fixture.send($0) }, previewCache: try cache())
    let listed = try await client.list(source: source, path: "/photos")
    let photo = try XCTUnwrap(listed.photos.first)
    do { _ = try await client.preview(photo, pixels: 512); XCTFail("Expected missing dependency") }
    catch { XCTAssertTrue(error.localizedDescription.contains("Pillow")) }
    let counts = await fixture.counts
    XCTAssertNil(counts["fetch"])
  }
  func testSimultaneousConsumersShareOnePreviewAndBoundedCacheEvicts() async throws {
    let fixture = PreviewFixture(), cache = try cache()
    let client = RelayRemoteClient(transport: { try await fixture.send($0) }, previewCache: cache)
    let listed = try await client.list(source: source, path: "/photos")
    let photo = try XCTUnwrap(listed.photos.first)
    async let a = client.preview(photo, pixels: 2048)
    async let b = client.preview(photo, pixels: 2048)
    _ = try await (a,b)
    let counts = await fixture.counts
    XCTAssertEqual(counts["preview"], 1)
    var result = BridgeAssetResult(); result.image = Data(repeating: 1, count: 10_000); result.fingerprint = "test"
    try await cache.write(result, key: "one")
    try await cache.write(result, key: "two")
    let evicted = await cache.read("one"), retained = await cache.read("two")
    XCTAssertNil(evicted); XCTAssertNotNil(retained)
  }
}

private actor PreviewFixture {
  var counts: [String: Int] = [:]
  var imageTransfers = 0
  var version = 1
  let failure: String?
  init(failure: String? = nil) { self.failure = failure }
  func change() { version += 1 }
  func send(_ request: BridgeRequest) async throws -> BridgeResponse {
    counts[request.operation, default: 0] += 1
    var response = BridgeResponse()
    switch request.operation {
    case "list":
      response.listingID = UUID()
      response.entries = [BridgeEntry(name: "a.png", path: "/photos/a.png", directory: false,
        size: 12, modified: String(version), fingerprint: "version-\(version)")]
    case "preview":
      if let failure { throw BridgeError(failure) }
      try await Task.sleep(for: .milliseconds(10))
      var result = BridgeAssetResult(); result.fingerprint = "version-\(version)"
      if request.fingerprint == result.fingerprint { result.unchanged = true }
      else {
        imageTransfers += 1; result.image = Data([1,2,3])
        result.metadata = ["Dimensions": "3000 × 2000"]; result.sidecar = "{\"prompt\":\"fixture\"}"
      }
      response.asset = result
    case "release": break
    default: XCTFail("Unexpected operation: \(request.operation)")
    }
    return response
  }
}
