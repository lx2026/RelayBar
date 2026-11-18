import BridgeProtocol
import Foundation
import XCTest
@testable import FrameKit

final class RemoteTests: XCTestCase {
  private let source = BridgeSource(id: String(repeating: "a", count: 64), name: "Fixture")
  private func entry(_ name: String, size: Int64 = 12, directory: Bool = false) -> BridgeEntry {
    BridgeEntry(name: name, path: "/photos/" + name, directory: directory, size: size, modified: "fixture time")
  }
  private func client(_ entries: [BridgeEntry]) -> RelayRemoteClient {
    RelayRemoteClient(transport: { request in
      guard request.operation == "list" || request.operation == "release" else { throw BridgeError("No fetch expected") }
      var response = BridgeResponse(); response.listingID = UUID(); response.entries = entries
      return response
    })
  }
  func testPathAndSourceValidation() {
    for path in ["relative", "/a/../secret", "/a/./b", "/a\nb", "/a\0b"] { XCTAssertFalse(FrameBridgeEnvironment.validPath(path)) }
    XCTAssertTrue(FrameBridgeEnvironment.validPath("/space here/照片"))
    XCTAssertFalse(FrameBridgeEnvironment.validName("../a"))
    XCTAssertFalse(FrameBridgeEnvironment.validSource(BridgeSource(id: "bad/host", name: "Fixture")))
  }
  func testRememberOpenIsSeparateValidatedV2Request() async throws {
    let client = RelayRemoteClient(transport: { request in
      XCTAssertEqual(request.operation, "rememberOpen")
    XCTAssertEqual(request.version, FrameBridgeEnvironment.protocolVersion)
      XCTAssertEqual(request.sourceID, String(repeating: "a", count: 64))
      XCTAssertEqual(request.path, "/photos")
      XCTAssertNil(request.listingID)
      return BridgeResponse()
    })
    try await client.rememberOpen(source: source, path: "/photos")
    for path in ["relative", "/photos/../secret"] {
      do { try await client.rememberOpen(source: source, path: path); XCTFail("Invalid path remembered") } catch {}
    }
    let refused = RelayRemoteClient(transport: { _ in BridgeResponse(error: "Access revoked") })
    do { try await refused.rememberOpen(source: source, path: "/photos"); XCTFail("Expected refusal") }
    catch { XCTAssertEqual(error.localizedDescription, "Access revoked") }
  }
  func testListingPairsJSONWithoutFetchingAndKeepsFavoritesStable() async throws {
    let client = client([entry("one.png"), entry("one.png.json"), entry("two.jpg"), entry("two.png"), entry("two.json"), entry("nested", directory: true)])
    let first = try await client.list(source: source, path: "/photos")
    let second = try await client.list(source: source, path: "/photos")
    XCTAssertEqual(first.photos.count, 3)
    XCTAssertEqual(first.rootFolder.children.first?.relativePath, "/photos/nested")
    XCTAssertEqual(first.photos.first?.sidecar?.url.lastPathComponent, "one.png.json")
    XCTAssertNil(first.photos.last?.sidecar)
    XCTAssertEqual(first.photos.map(\.favoriteID), second.photos.map(\.favoriteID))
    XCTAssertNotEqual(first.photos.first?.contentID, second.photos.first?.contentID)
    XCTAssertTrue(first.photos.allSatisfy { $0.remote != nil && !$0.url.isFileURL })
  }
  func testInvalidAndDuplicateListingPathsAreRejected() async {
    let wrong = BridgeEntry(name: "a.jpg", path: "/secret/a.jpg", directory: false, size: 10, modified: "")
    for values in [[wrong], [entry("a.jpg"), entry("a.jpg")]] {
      do { _ = try await client(values).list(source: source, path: "/photos"); XCTFail("Accepted invalid listing") }
      catch {}
    }
  }
  func testRepeatedOrUnrequestedEntriesInRepliesAreRejected() async throws {
    func stats(_ entries: [BridgeEntry]) -> RelayRemoteClient {
      RelayRemoteClient(transport: { request in
        var response = BridgeResponse()
        if request.operation == "documentStat" { var result = BridgeAssetResult(); result.entries = entries; response.asset = result }
        return response
      })
    }
    let page = entry("page.html"), style = entry("style.css")
    for reply in [[page, page], [page, entry("other.css")], [page, entry("style.css", directory: true)]] {
      do {
        _ = try await stats(reply).documentStats(source: source, root: "/photos", paths: [page.path, style.path])
        XCTFail("Accepted \(reply.map(\.path))")
      } catch { XCTAssertEqual(error.localizedDescription, "Invalid resource response.") }
    }
    let accepted = try await stats([style]).documentStats(source: source, root: "/photos", paths: [page.path, style.path])
    XCTAssertEqual(accepted, [style], "A missing file is simply absent")
    // The document view refreshes through this reply; a repeated path is an error there, not a crash.
    let resources = DocumentResources(location: .remote(source, "/photos"), client: stats([page, page]))
    do { _ = try await resources.data(at: "page.html") } catch {}
    do { _ = try await resources.refresh(); XCTFail("Accepted a repeated path") }
    catch { XCTAssertEqual(error.localizedDescription, "Invalid resource response.") }

    func archive(_ records: [BridgeStoredAsset]) -> RelayRemoteClient {
      RelayRemoteClient(transport: { request in
        var response = BridgeResponse(); response.listingID = UUID()
        if request.operation == "collection" { var result = BridgeAssetResult(); result.records = records; response.asset = result }
        return response
      })
    }
    let id = UUID()
    func record(_ id: UUID, folder: String) -> BridgeStoredAsset {
      BridgeStoredAsset(id: id, members: [BridgeEntry(name: "a.jpg", path: "/photos/Archive/\(folder)/a.jpg", directory: false, size: 4, modified: "")],
                        originals: ["/photos/a.jpg"])
    }
    for records in [[record(id, folder: "one"), record(id, folder: "two")], [record(id, folder: "one"), record(UUID(), folder: "one")]] {
      do { _ = try await archive(records).archivedAssets(source: source, root: "/photos"); XCTFail("Accepted a repeated record") }
      catch { XCTAssertEqual(error.localizedDescription, "Invalid archive response.") }
    }
    let archived = try await archive([record(id, folder: "one"), record(UUID(), folder: "two")]).archivedAssets(source: source, root: "/photos")
    XCTAssertEqual(archived.count, 2, "The same original archived twice is two records")
  }
  func testListingGroupsArbitraryCompanionsWithoutDownloads() async throws {
    let client = client(["name1.png", "name1.prompt.json", "name1.xyz.json", "name1.qqq.txt", "name10.txt"].map { entry($0) })
    let photo = try await client.list(source: source, path: "/photos").photos[0]
    XCTAssertEqual(photo.companions.map { $0.url.lastPathComponent }, ["name1.prompt.json", "name1.xyz.json", "name1.qqq.txt"])
    XCTAssertEqual(photo.remote?.companions.map(\.name), photo.companions.map { $0.url.lastPathComponent })
    XCTAssertEqual(photo.exportMembers.count, 4)
  }
  func testRemoteCannotEnterTrashOrArchive() async throws {
    let scan = try await client([entry("a.jpg")]).list(source: source, path: "/photos")
    let result = await BatchTrash.move(scan.photos) { _ in XCTFail("Called local mutation"); throw BridgeError("bad") }
    XCTAssertEqual(result.failures.count, 1)
    XCTAssertThrowsError(try ArchiveService.archive(scan.photos[0], root: URL(fileURLWithPath: "/private/tmp")))
  }
  func testRemoteVideoAndOversizedImageDoNotFetchImplicitly() async throws {
    let client = client([entry("a.mp4"), entry("big.jpg", size: 101 * 1_024 * 1_024)])
    let photos = try await client.list(source: source, path: "/photos").photos
    for photo in photos {
      do { _ = try await client.resolve(photo); XCTFail("Expected bounded refusal") }
      catch { XCTAssertFalse(error.localizedDescription.contains("No fetch expected")) }
    }
  }
  func testDownloadIsExactDeduplicatedAndCacheIsPrivate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRemoteTest-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let job = UUID(), folder = "FrameTransfers-\(UUID())/\(job)"
    let directory = root.appendingPathComponent(folder)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = Data("image-bytes!".utf8)
    try data.write(to: directory.appendingPathComponent("a.jpg"))
    let transfer = FixtureTransport(entries: [entry("a.jpg")], job: job, path: folder + "/a.jpg")
    let client = RelayRemoteClient(transport: { try await transfer.send($0) }, cacheRoot: root.appendingPathComponent("private"), sharedRoot: { root })
    let photo = try await client.list(source: source, path: "/photos").photos[0]
    async let first = client.resolve(photo)
    async let second = client.resolve(photo)
    let (a, b) = try await (first, second)
    XCTAssertEqual(a.url, b.url)
    XCTAssertTrue(a.url.path.hasPrefix(root.appendingPathComponent("private").path))
    XCTAssertNil(a.remote)
    XCTAssertEqual(try Data(contentsOf: a.url), data)
    let count = await transfer.fetches
    XCTAssertEqual(count, 1)
    await client.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: a.url.path))
  }
  func testFileWhoseNameStartsWithACombiningMarkDownloads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRemoteTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    // The mark fuses with the slash before it into one Swift character, but the name is ordinary to the file system.
    let name = "\u{301}accent.png", job = UUID(), folder = "FrameTransfers-\(UUID())/\(job)"
    try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    try Data("accent-bytes".utf8).write(to: root.appendingPathComponent(folder + "/" + name))
    let transfer = FixtureTransport(entries: [entry(name)], job: job, path: folder + "/" + name)
    let client = RelayRemoteClient(transport: { try await transfer.send($0) }, cacheRoot: root.appendingPathComponent("private"), sharedRoot: { root })
    let listed = try await client.list(source: source, path: "/photos").photos
    let photo = try XCTUnwrap(listed.first)
    let local: PhotoItem
    do { local = try await client.resolve(photo) } catch { XCTFail("Download failed: \(error)"); return }
    XCTAssertEqual(try Data(contentsOf: local.url), Data("accent-bytes".utf8))
    await client.clear()
  }
  func testCancelledPendingListReleasesBrokerJob() async throws {
    let transport = PendingTransport()
    let client = RelayRemoteClient(transport: { await transport.send($0) })
    let source = source
    let task = Task { try await client.list(source: source, path: "/photos") }
    try await Task.sleep(for: .milliseconds(40)); task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
    for _ in 0..<40 {
      if await transport.released { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let released = await transport.released
    XCTAssertTrue(released)
  }
  @MainActor func testSelectedRemoteVideoDownloadsOnceAndPlaysNativelyWithoutHostPreviewTools() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameVideoTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let job = UUID(), folder = "FrameTransfers-fixture/\(job)"
    let directory = root.appendingPathComponent(folder)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceFile = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/landscape.mp4")
    try FileManager.default.copyItem(at: sourceFile, to: directory.appendingPathComponent("a.mp4"))
    let size = Int64(try sourceFile.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
    let transport = FixtureTransport(entries: [entry("a.mp4", size: size)], job: job, path: folder + "/a.mp4")
    let client = RelayRemoteClient(transport: { try await transport.send($0) }, cacheRoot: root.appendingPathComponent("private"), sharedRoot: { root })
    let photo = try await client.list(source: source, path: "/photos").photos[0]
    let player = PlaybackController()
    let metadata = VideoMetadataReader()
    player.prepare(photo, downloadOriginal: true) { photo in
      let local = try await client.resolve(photo, allowVideo: true)
      let info = await metadata.info(for: local)
      return (local, info)
    }
    for _ in 0..<200 where player.isPreparing { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNotNil(player.player)
    XCTAssertNil(player.failure)
    let fetches = await transport.fetches, previewRequests = await transport.previewRequests
    XCTAssertEqual(fetches, 1)
    XCTAssertEqual(previewRequests, 0)
    player.clear()
    await client.clear()
  }
  func testEvictedListingRenewsAndFetchesOldThumbnail() async throws {
    try await checkRenewal(changed: false)
  }
  func testRenewalRefusesChangedSameSizedFile() async throws {
    try await checkRenewal(changed: true)
  }
  func testBatchMutationRenewsExpiredListingButRefusesChangedAsset() async throws {
    for changed in [false, true] {
      let transport = ExpiringListingTransport(changed: changed)
      let client = RelayRemoteClient(transport: { await transport.send($0) })
      let photo = try await client.list(source: source, path: "/photos").photos[0]
      for n in 0..<40 { _ = try await client.list(source: source, path: "/other\(n)") }
      do {
        let id = try await client.mutate(photo, action: "archive", root: "/photos")
        XCTAssertFalse(changed); XCTAssertNotNil(id)
      } catch {
        XCTAssertTrue(changed)
        XCTAssertEqual(error.localizedDescription, "The remote asset changed. Refresh before changing it.")
      }
      let counts = await transport.counts, remembered = await transport.remembered
      XCTAssertEqual(counts.0, 2)
      XCTAssertEqual(counts.1, changed ? 0 : 1)
      XCTAssertEqual(remembered, 0)
    }
  }
  private func checkRenewal(changed: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRenewal-\(UUID())")
    let transport = ExpiringListingTransport(changed: changed)
    let job = transport.job
    let directory = root.appendingPathComponent("FrameTransfers-fixture/\(job)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("image-bytes!".utf8).write(to: directory.appendingPathComponent("a.jpg"))
    defer { try? FileManager.default.removeItem(at: root) }
    let client = RelayRemoteClient(transport: { await transport.send($0) }, cacheRoot: root.appendingPathComponent("private"), sharedRoot: { root })
    let photo = try await client.list(source: source, path: "/photos").photos[0]
    for n in 0..<40 { _ = try await client.list(source: source, path: "/other\(n)") }
    do {
      let result = try await client.resolve(photo)
      XCTAssertFalse(changed)
      XCTAssertEqual(try Data(contentsOf: result.url), Data("image-bytes!".utf8))
    } catch {
      XCTAssertTrue(changed)
      XCTAssertEqual(error.localizedDescription, "The remote file changed. Refresh the folder before downloading.")
    }
    let counts = await transport.counts
    XCTAssertEqual(counts.0, 2)
    XCTAssertEqual(counts.1, changed ? 0 : 1)
    let remembered = await transport.remembered
    XCTAssertEqual(remembered, 0, "Thumbnail renewal is passive")
    await client.clear()
  }
}

private actor ExpiringListingTransport {
  let job = UUID()
  let changed: Bool
  var listings: [UUID] = []
  var targetLists = 0, downloads = 0
  var remembered = 0
  var counts: (Int, Int) { (targetLists, downloads) }
  init(changed: Bool) { self.changed = changed }
  func send(_ request: BridgeRequest) -> BridgeResponse {
    var response = BridgeResponse()
    if request.operation == "rememberOpen" { remembered += 1 }
    if request.operation == "list" {
      let id = UUID(); listings.append(id)
      if listings.count > 32 { listings.removeFirst() }
      response.listingID = id; response.entries = []
      if request.path == "/photos" {
        targetLists += 1
        response.entries = [BridgeEntry(name: "a.jpg", path: "/photos/a.jpg", directory: false, size: 12,
          modified: changed && targetLists > 1 ? "changed" : "unchanged")]
      }
    }
    if request.operation == "fetch" || request.operation == "archive" {
      guard let id = request.listingID, listings.contains(id) else {
        return BridgeResponse(error: "Refresh this remote folder before downloading.")
      }
      downloads += 1; response.jobID = job
      response.cacheRelativePath = "FrameTransfers-fixture/\(job)/a.jpg"
      if request.operation == "archive" { var result = BridgeAssetResult(); result.recordID = UUID(); response.asset = result }
    }
    return response
  }
}

private actor FixtureTransport {
  let entries: [BridgeEntry]; let job: UUID; let path: String
  var fetches = 0
  var previewRequests = 0
  init(entries: [BridgeEntry], job: UUID, path: String) { self.entries = entries; self.job = job; self.path = path }
  func send(_ request: BridgeRequest) async throws -> BridgeResponse {
    var value = BridgeResponse()
    if request.operation == "preview" { previewRequests += 1; throw BridgeError("ffmpeg not installed") }
    if request.operation == "list" { value.entries = entries; value.listingID = UUID() }
    if request.operation == "fetch" {
      fetches += 1; try await Task.sleep(for: .milliseconds(30))
      value.jobID = job; value.cacheRelativePath = path
    }
    return value
  }
}
private actor PendingTransport {
  let job = UUID(); var released = false
  func send(_ request: BridgeRequest) -> BridgeResponse {
    if request.operation == "release" { released = true; return BridgeResponse() }
    var response = BridgeResponse(); response.jobID = job; response.status = "pending"; return response
  }
}
