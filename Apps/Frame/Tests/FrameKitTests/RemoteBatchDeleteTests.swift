import BridgeProtocol
import Foundation
import XCTest
@testable import FrameKit

final class RemoteBatchDeleteTests: XCTestCase {
  func testRecursiveBatchRenewsWithinRetainedListingLimit() async throws {
    let fixture = RetainedDeleteFixture()
    let client = RelayRemoteClient(transport: { await fixture.send($0) })
    let source = BridgeSource(id: String(repeating: "c", count: 64), name: "Fixture")
    var photos: [PhotoItem] = []
    for index in 0..<70 { photos += try await client.list(source: source, path: "/photos/\(index)").photos }
    let failures = await client.delete(photos, root: "/photos")
    XCTAssertTrue(failures.isEmpty)
    let invocations = await fixture.invocations
    XCTAssertEqual(invocations, 5, "Bounded groups of listings must not become per-file delete jobs")
  }
  func testHundredAssetsUseOneRequestAndReturnIndividualFailures() async throws {
    let fixture = BatchDeleteFixture()
    let client = RelayRemoteClient(transport: { await fixture.send($0) })
    let source = BridgeSource(id: String(repeating: "c", count: 64), name: "Fixture")
    let photos = try await client.list(source: source, path: "/photos").photos
    XCTAssertEqual(photos.count, 100)
    let failures = await client.delete(photos, root: "/photos")
    let requests = await fixture.requests
    XCTAssertEqual(requests.filter { $0.operation == "deleteBatch" }.count, 1)
    XCTAssertEqual(requests.first { $0.operation == "deleteBatch" }?.targets?.count, 100)
    XCTAssertEqual(requests.filter { $0.operation == "list" }.count, 1)
    XCTAssertFalse(requests.contains { ["delete", "fetch", "rememberOpen"].contains($0.operation) })
    XCTAssertEqual(failures.map { $0.photo.name }, ["40.jpg"])
  }
}

private actor RetainedDeleteFixture {
  var retained: [UUID] = [], invocations = 0
  func send(_ request: BridgeRequest) -> BridgeResponse {
    var response = BridgeResponse()
    switch request.operation {
    case "list":
      let id = UUID(); retained.append(id)
      if retained.count > 32 { retained.removeFirst() }
      response.listingID = id
      response.entries = [BridgeEntry(name: "a.png", path: request.path! + "/a.png", directory: false, size: 12, modified: "same", fingerprint: "same")]
    case "deleteBatch":
      guard request.targets!.allSatisfy({ retained.contains($0.listingID) }) else {
        return BridgeResponse(error: "Refresh this remote folder before deleting.")
      }
      invocations += 1
      var result = BridgeAssetResult()
      result.outcomes = request.targets!.map { BridgeDeleteOutcome(path: $0.path) }
      response.asset = result
    case "release": break
    default: XCTFail("Unexpected operation: \(request.operation)")
    }
    return response
  }
}

private actor BatchDeleteFixture {
  var requests: [BridgeRequest] = []
  func send(_ request: BridgeRequest) -> BridgeResponse {
    requests.append(request)
    var result = BridgeResponse()
    switch request.operation {
    case "list":
      result.listingID = UUID()
      result.entries = (0..<100).flatMap { index in
        ["\(index).jpg", "\(index).jpg.json"].map {
          BridgeEntry(name: $0, path: "/photos/" + $0, directory: false, size: 12, modified: "fixture", fingerprint: "fixture")
        }
      }
    case "deleteBatch":
      var asset = BridgeAssetResult()
      asset.outcomes = request.targets?.map { BridgeDeleteOutcome(path: $0.path, error: $0.path == "/photos/40.jpg" ? "Permission denied" : nil) }
      result.asset = asset
    case "release": break
    default: XCTFail("Unexpected operation: \(request.operation)")
    }
    return result
  }
}
