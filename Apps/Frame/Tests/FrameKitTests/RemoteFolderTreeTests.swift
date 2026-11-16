import BridgeProtocol
import Composition
import Foundation
import XCTest
@testable import FrameKit

final class RemoteFolderTreeTests: XCTestCase {
  private let source = BridgeSource(id: String(repeating: "a", count: 64), name: "Fixture")
  @MainActor private func index(_ fixture: TreeFixture, path: String = "/photos") -> RemoteFolderIndex {
    RemoteFolderIndex(source: source, path: path, loader: { try await fixture.load($1) })
  }
  @MainActor func testShutdownDrainsSupersededLoadsAndRejectsWarmCache() async throws {
    let fixture = DelayedTreeFixture()
    let tree = RemoteFolderIndex(source: source, path: "/photos", loader: { try await fixture.load($1) })
    _ = try await tree.load("/photos")
    let first = Task { try await tree.load("/photos/A") }
    try await fixture.waitFor(1)
    tree.cancelAll()
    let second = Task { try await tree.load("/photos/A") }
    try await fixture.waitFor(2)
    var drained = false
    let shutdown = Task { await tree.shutdown(); drained = true }
    for _ in 0..<100 where !tree.isStopped { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(tree.isStopped)
    await fixture.release(2)
    do { _ = try await second.value; XCTFail("Stopped tree returned a late read") } catch {}
    XCTAssertFalse(drained, "The superseded load is still owned after cancelAll removes its flight")
    do { _ = try await tree.load("/photos"); XCTFail("Stopped tree returned its warm cache") } catch {}
    await fixture.release(1)
    do { _ = try await first.value; XCTFail("Superseded read returned content") } catch {}
    await shutdown.value
    XCTAssertTrue(tree.loading.isEmpty)
    XCTAssertNil(tree.nodes["/photos/A"])
  }

  @MainActor func testLateCancelledReadCannotEscapeOrReplaceNewDirectory() async throws {
    let fixture = DelayedTreeFixture()
    let tree = RemoteFolderIndex(source: source, path: "/photos", loader: { try await fixture.load($1) })
    let first = Task { try await tree.load("/photos/A") }
    try await fixture.waitFor(1)
    tree.invalidate("/photos/A")
    let second = Task { try await tree.load("/photos/A") }
    try await fixture.waitFor(2)
    await fixture.release(2)
    let latest = try await second.value
    XCTAssertEqual(latest.photos.count, 2)
    await fixture.release(1)
    do { _ = try await first.value; XCTFail("Old request escaped invalidation") } catch {}
    XCTAssertEqual(tree.files(at: "/photos/A").count, 2)
    await tree.shutdown()
  }
  @MainActor func testExpansionIsLazyCachedAndDoesNotReplaceRoot() async throws {
    let fixture = TreeFixture(), tree = index(fixture)
    _ = try await tree.load("/photos")
    XCTAssertEqual(tree.rows.map(\.id), ["/photos", "/photos/A", "/photos/B"])
    XCTAssertFalse(tree.nodes["/photos/A"]!.isLoaded)
    tree.setExpanded("/photos/A", true)
    _ = try await tree.load("/photos/A")
    _ = try await tree.load("/photos/A")
    let calls = await fixture.paths
    XCTAssertEqual(calls, ["/photos", "/photos/A"])
    XCTAssertEqual(tree.rows.map(\.id), ["/photos", "/photos/A", "/photos/A/deep", "/photos/B"])
    XCTAssertEqual(tree.rootPath, "/photos")
    tree.setExpanded("/photos/A", false)
    XCTAssertEqual(tree.rows.count, 3)
    tree.reveal("/")
    XCTAssertEqual(tree.rootPath, "/")
    XCTAssertTrue(tree.nodes["/photos/A"]!.isLoaded)
    XCTAssertEqual(tree.rows.map(\.id), ["/", "/photos", "/photos/A", "/photos/B"])
  }

  @MainActor func testConcurrentExpansionDeduplicatesAndOneCancellationDoesNotCancelAnother() async throws {
    let fixture = TreeFixture(delay: .milliseconds(40)), tree = index(fixture)
    let first = Task { try await tree.load("/photos") }
    let second = Task { try await tree.load("/photos") }
    try await Task.sleep(for: .milliseconds(10)); first.cancel()
    do { _ = try await first.value; XCTFail("Expected cancellation") } catch {}
    _ = try await second.value
    let calls = await fixture.paths
    XCTAssertEqual(calls, ["/photos"])
    XCTAssertTrue(tree.loading.isEmpty)
    XCTAssertTrue(tree.nodes["/photos"]!.isLoaded)
  }
  @MainActor func testScanVisitsDescendantsOnceAndPublishesProgressWithoutFetching() async throws {
    let fixture = TreeFixture(), tree = index(fixture)
    var snapshots: [RemoteScanSnapshot] = []
    try await RemoteSubfolderScan.run(index: tree, path: "/photos") { snapshots.append($0) }
    let result = try XCTUnwrap(snapshots.last)
    XCTAssertTrue(result.finished)
    XCTAssertEqual(result.folders, 4)
    XCTAssertEqual(result.photos.count, 4)
    XCTAssertEqual(Set(result.photos.map(\.folderRelativePath)), ["/photos", "/photos/A", "/photos/B", "/photos/A/deep"])
    XCTAssertEqual(snapshots.first?.folders, 1)
    XCTAssertTrue(result.issues.isEmpty)
  }
  @MainActor func testBoundsAndFailuresKeepPartialResults() async throws {
    let tree = index(TreeFixture())
    var last: RemoteScanSnapshot?
    try await RemoteSubfolderScan.run(index: tree, path: "/photos", maximumFolders: 2) { last = $0 }
    XCTAssertEqual(last?.folders, 2)
    XCTAssertEqual(last?.photos.count, 2)
    XCTAssertTrue(last?.issues.first?.contains("2 folders") == true)
    try await RemoteSubfolderScan.run(index: tree, path: "/photos", maximumAssets: 2) { last = $0 }
    XCTAssertEqual(last?.photos.count, 2)
    XCTAssertTrue(last?.issues.first?.contains("2 files") == true)
    let failed = index(TreeFixture(failing: "/photos/A"))
    try await RemoteSubfolderScan.run(index: failed, path: "/photos") { last = $0 }
    XCTAssertEqual(last?.photos.count, 2)
    XCTAssertTrue(last?.issues.first?.contains("Permission denied") == true)
    XCTAssertEqual(failed.nodes["/photos/A"]?.error, "Permission denied")
  }
  @MainActor func testCancellationPreventsLateProgressAndClearsLoads() async throws {
    let fixture = TreeFixture(delay: .milliseconds(40)), tree = index(fixture)
    var publishes = 0
    let task = Task { try await RemoteSubfolderScan.run(index: tree, path: "/photos") { _ in publishes += 1 } }
    try await Task.sleep(for: .milliseconds(10)); task.cancel()
    do { try await task.value; XCTFail("Expected cancellation") } catch {}
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(publishes, 0)
    XCTAssertTrue(tree.loading.isEmpty)
    XCTAssertFalse(tree.nodes["/photos"]!.isLoaded)
  }
  @MainActor func testNavigationPreservesTreeAndHidingRemoteCancelsAndPersists() async throws {
    let fixture = TreeFixture(), suite = "FrameTree.\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("FrameTreeSettings-\(UUID())")
    defer { try? FileManager.default.removeItem(at: state) }
    let storage = state.appendingPathComponent("preferences.json")
    let store = makeRemoteStore(defaults: defaults, preferencesURL: storage, remoteCatalogLoader: { BridgeResponse() },
      remoteFolderLoader: { try await fixture.load($1) }, remoteOpenRecorder: { _, _ in }, actions: FixtureRemoteActions())
    await store.openRemote(source, path: "/photos")
    let tree = try XCTUnwrap(store.remoteFolders)
    await store.openRemote(source, path: "/photos/A")
    XCTAssertTrue(store.remoteFolders === tree)
    XCTAssertEqual(tree.rootPath, "/photos")
    XCTAssertEqual(store.selectedFolderPath, "/photos/A")
    XCTAssertEqual(store.visiblePhotos.map(\.folderRelativePath), ["/photos/A"])
    store.setViewMode(.contactSheet)
    XCTAssertTrue(store.canDelete)
    await store.setIncludesSubfolders(true)
    for _ in 0..<100 where store.isScanningSubfolders { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(store.photos.count, 2)
    await store.setIncludesSubfolders(false)
    XCTAssertEqual(store.photos.count, 1)
    await store.setShowsRemoteFolders(false)
    XCTAssertNil(store.remoteFolders)
    XCTAssertNil(store.activeRootID)
    XCTAssertTrue(store.photos.isEmpty)
    XCTAssertFalse(store.isScanningSubfolders)
    let reopened = makeRemoteStore(defaults: defaults, preferencesURL: storage)
    try await reopened.previews.start()
    XCTAssertFalse(reopened.showsRemoteFolders)
    XCTAssertNil(defaults.object(forKey: "showsRemoteFolders"))
    await reopened.shutdown()
    await store.openRemote(source, path: "/photos")
    XCTAssertNil(store.remoteFolders)
    await store.shutdown()
  }
  @MainActor func testHiddenRemoteNeverReadsCatalogOrAcceptsHandoff() async {
    let suite = "FrameHidden.\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = makeRemoteStore(defaults: defaults, remoteCatalogLoader: { XCTFail("Catalog read while hidden"); return BridgeResponse() })
    await store.setShowsRemoteFolders(false)
    await store.refreshRemoteLocations()
    await store.handleHandoff(URL(string: "frame-viewer://handoff/\(UUID())")!)
    XCTAssertEqual(store.errorMessage, "Remote folders are hidden. Enable them in Frame Settings.")
  }
  @MainActor func testNewNavigationAndStopRejectOldRecursiveResults() async throws {
    let fixture = TreeFixture(delay: .milliseconds(15))
    let store = makeRemoteStore(remoteCatalogLoader: { BridgeResponse() }, remoteFolderLoader: { try await fixture.load($1) },
      remoteOpenRecorder: { _, _ in })
    await store.openRemote(source, path: "/photos")
    await store.setIncludesSubfolders(true)
    store.stopRemoteScan()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(store.photos.count, 1)
    XCTAssertNotNil(store.remoteScanIssue)
    await store.openRemote(source, path: "/photos/B")
    for _ in 0..<100 where store.isScanningSubfolders { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(store.photos.allSatisfy { $0.folderRelativePath == "/photos/B" })
  }
  func testLocalTreeIncludesEmptyFoldersAndDirectScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameTree-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty/Deeper"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("fixture".utf8).write(to: root.appendingPathComponent("a.jpg"))
    try Data("fixture".utf8).write(to: root.appendingPathComponent("Empty/Deeper/b.jpg"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("No media"), withIntermediateDirectories: true)
    let result = try FileScanner.scan(rootURL: root, rootID: UUID())
    XCTAssertEqual(result.rootFolder.children.map(\.name), ["Empty", "No media"])
    XCTAssertEqual(result.rootFolder.children.last?.photoCount, 0)
    XCTAssertEqual(PhotoQuery.visiblePhotos(in: result.photos, folderRelativePath: "", filter: .all, favorites: [], includeSubfolders: false).count, 1)
    XCTAssertEqual(PhotoQuery.visiblePhotos(in: result.photos, folderRelativePath: "Empty", filter: .all, favorites: [], includeSubfolders: false).count, 0)
    XCTAssertEqual(PhotoQuery.visiblePhotos(in: result.photos, folderRelativePath: "Empty", filter: .all, favorites: []).count, 1)
  }
  @MainActor func testOnlyExplicitSuccessfulOpensReachHistoryEvenWithCachedFolders() async throws {
    let fixture = TreeFixture(), history = OpenHistoryFixture()
    let store = makeRemoteStore(remoteCatalogLoader: { BridgeResponse() },
      remoteFolderLoader: { try await fixture.load($1) }, remoteOpenRecorder: { await history.record($1) })
    await store.openRemote(source, path: "/photos")
    store.toggleRemoteFolder("/photos/A")
    for _ in 0..<100 where store.remoteFolders?.nodes["/photos/A"]?.isLoaded != true {
      try await Task.sleep(for: .milliseconds(5))
    }
    await store.setIncludesSubfolders(true)
    for _ in 0..<100 where store.isScanningSubfolders { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(store.photos.count, 4)
    var opened = await history.paths
    XCTAssertEqual(opened, [])
    let loadsBefore = await fixture.paths.count
    await store.openRemote(source, path: "/photos/A")
    let loadsAfter = await fixture.paths.count
    XCTAssertEqual(loadsAfter, loadsBefore, "Cached explicit open must not relist over SSH")
    opened = await history.paths
    XCTAssertEqual(opened, [])
    await store.setIncludesSubfolders(false)
    store.refresh()
    for _ in 0..<100 {
      if await fixture.paths.count > loadsAfter, !store.isScanning { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let refreshedLoads = await fixture.paths.count
    XCTAssertGreaterThan(refreshedLoads, loadsAfter)
    opened = await history.paths
    XCTAssertEqual(opened, [], "Frame never changes RelayBar recents")
    store.remoteParent()
    for _ in 0..<100 {
      if store.remotePath == "/photos", !store.isScanning { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    opened = await history.paths
    XCTAssertEqual(opened, [])
  }
  @MainActor func testFailedSupersededAndHiddenOpensNeverReachHistory() async throws {
    let fixture = TreeFixture(delay: .milliseconds(40), failing: "/photos/B"), history = OpenHistoryFixture()
    let suite = "FrameHistory.\(UUID())", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = makeRemoteStore(defaults: defaults, remoteCatalogLoader: { BridgeResponse() },
      remoteFolderLoader: { try await fixture.load($1) }, remoteOpenRecorder: { await history.record($1) })
    let source = source
    let abandoned = Task { await store.openRemote(source, path: "/photos") }
    try await Task.sleep(for: .milliseconds(5))
    await store.openRemote(source, path: "/photos/A")
    await abandoned.value
    await store.openRemote(source, path: "/photos/B")
    XCTAssertNotNil(store.remoteError)
    await store.setShowsRemoteFolders(false)
    await store.openRemote(source, path: "/photos")
    let opened = await history.paths
    XCTAssertEqual(opened, [])
  }
  @MainActor func testEmptyCachedFolderIsRememberedAndHistoryFailureKeepsView() async throws {
    let history = OpenHistoryFixture()
    let store = makeRemoteStore(remoteCatalogLoader: { BridgeResponse() }, remoteFolderLoader: { _, path in
      TreeFixture.result(path, children: [], count: 0)
    }, remoteOpenRecorder: { _, path in
      await history.record(path)
      throw BridgeError("RelayBar disconnected")
    })
    await store.openRemote(source, path: "/photos")
    await store.openRemote(source, path: "/photos")
    let opened = await history.paths
    XCTAssertEqual(opened, [])
    XCTAssertEqual(store.rootFolder?.relativePath, "/photos")
    XCTAssertNil(store.remoteError)
    XCTAssertFalse(store.isScanning)
    XCTAssertNil(store.errorMessage)
  }
  @MainActor func testLargeSyntheticTreeIsBoundedAndFast() async throws {
    let tree = RemoteFolderIndex(source: source, path: "/photos", loader: { _, path in
      let children = path == "/photos" ? (0..<600).map { FolderNode(id: "\(path)/\($0)", name: "\($0)", relativePath: "\(path)/\($0)", photoCount: 0, children: []) } : []
      return TreeFixture.result(path, children: children, count: 20)
    })
    let start = ContinuousClock.now
    var result: RemoteScanSnapshot?
    try await RemoteSubfolderScan.run(index: tree, path: "/photos") { result = $0 }
    let elapsed = start.duration(to: .now)
    XCTAssertEqual(result?.folders, 512)
    XCTAssertEqual(result?.photos.count, 10_240)
    XCTAssertTrue(result?.issues.first?.contains("512 folders") == true)
    XCTAssertEqual(tree.nodes.count, 601)
    print("PERFORMANCE synthetic-512-remote-folders-10240-assets=\(elapsed)")
    XCTAssertLessThan(elapsed, .seconds(10))
  }
}

private actor DelayedTreeFixture {
  private var next = 0
  private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
  func load(_ path: String) async throws -> ScanResult {
    if path == "/photos" { return TreeFixture.result(path, children: []) }
    next += 1
    let id = next
    await withCheckedContinuation { pending[id] = $0 }
    return TreeFixture.result(path, children: [], count: id)
  }
  func release(_ id: Int) { pending.removeValue(forKey: id)?.resume() }
  func waitFor(_ id: Int) async throws {
    for _ in 0..<500 {
      if pending[id] != nil { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Directory request did not start")
  }
}

private actor OpenHistoryFixture {
  var paths: [String] = []
  func record(_ path: String) { paths.append(path) }
}

private actor TreeFixture {
  var paths: [String] = []
  let delay: Duration
  let failing: String?
  init(delay: Duration = .zero, failing: String? = nil) { self.delay = delay; self.failing = failing }
  func load(_ path: String) async throws -> ScanResult {
    paths.append(path)
    if delay != .zero { try await Task.sleep(for: delay) }
    if path == failing { throw BridgeError("Permission denied") }
    let names = path == "/photos" ? ["A", "B"] : path == "/photos/A" ? ["deep"] : []
    let children = names.map { FolderNode(id: path + "/" + $0, name: $0, relativePath: path + "/" + $0, photoCount: 0, children: []) }
    return Self.result(path, children: children)
  }
  nonisolated static func result(_ path: String, children: [FolderNode], count: Int = 1) -> ScanResult {
    let photos = (0..<count).map { n in
      PhotoItem(id: path + "/\(n).jpg", rootID: UUID(), url: URL(fileURLWithPath: "/not-a-real-frame-fixture/\(n).jpg"),
        relativePath: path + "/\(n).jpg", folderRelativePath: path, name: "\(n).jpg", format: .jpeg,
        fileSize: 1, createdAt: nil, modifiedAt: nil, fileIdentifier: nil)
    }
    return ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: (path as NSString).lastPathComponent,
      relativePath: path, photoCount: photos.count, children: children))
  }
}
