import Combine
import Foundation
import RelayTransport
import Testing

@testable import MobileCore

private actor SearchFixture: RemoteFiles {
  var listed: [String] = []
  let folders: [String: [FileRow]]
  private var interruption: SFTPError?
  func interrupt(with error: SFTPError?) { interruption = error }
  var unreadable: Set<String> = []
  func denyListing(_ path: String) { unreadable.insert(path) }
  let pause: String?
  init(_ tree: [String: [String]], pause: String? = nil) {
    folders = tree.mapValues { names in
      names.map { name in
        var row = FileRow(
          name: name.trimmingCharacters(in: CharacterSet(charactersIn: "/@")),
          stamp: .init(directory: name.hasSuffix("/") || name.hasSuffix("@")))
        row.symbolicLink = name.hasSuffix("@")
        return row
      }
    }
    self.pause = pause
  }
  func list(_ path: String) async throws -> [FileRow] {
    listed.append(path)
    if let interruption { throw interruption }
    if unreadable.contains(path) { throw CocoaError(.fileReadNoPermission) }
    if path == pause { try await Task.sleep(for: .seconds(60)) }
    return folders[path] ?? []
  }
  func home() -> String { "/home" }
  func resolve(_ path: String) -> String { path }
  func stat(_ path: String) throws -> FileStamp { throw CocoaError(.fileReadUnknown) }
  func read(_ path: String, limit: Int) throws -> Data {
    Issue.record("Name index read file contents")
    throw CocoaError(.fileReadUnknown)
  }
}

private func finished(_ index: NameIndex, _ query: String) async throws -> ([NameHit], String?) {
  let (_, hits, status) = try #require(
    await index.results(query, visits: [], since: nil, waitForIndex: true))
  let diagnostics = await index.diagnostics
  #expect(status?.hasPrefix("Indexing") != true, "\(diagnostics)")
  return (hits, status)
}

@Test func breadthFirstResumeAndDeferredSearch() async throws {
  let store = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: store) }
  let host = Profile(host: "test.invalid", account: "reader")
  let tree = [
    "/notes": ["a/", "b/", ".secret", "link@", "env/"],
    "/notes/a": ["deep/"], "/notes/b": ["first.md"], "/notes/a/deep": ["second.md"],
  ]
  func index(_ files: SearchFixture) -> NameIndex {
    NameIndex(
      files: files, directory: store, profile: host, fingerprint: "pin", home: "/home",
      pins: ["/notes"])
  }
  let first = SearchFixture(tree, pause: "/notes/b")
  let initial = index(first)
  await initial.prepare(deferred: true)
  #expect(await first.listed.isEmpty)
  _ = await initial.results("md", visits: [], since: nil)
  let deadline = ContinuousClock.now + .seconds(3)
  // Folders in one batch are listed together, so their order is not fixed.
  while await !first.listed.contains("/notes/b"), .now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  await initial.stop()
  #expect(await first.listed.sorted() == ["/home", "/notes", "/notes/a", "/notes/b"])
  let second = SearchFixture(tree)
  let restored = index(second)
  await restored.prepare(deferred: false)
  let matches = try await finished(restored, "md")
  #expect(matches.0.map(\.id) == ["/notes/b/first.md", "/notes/a/deep/second.md"])
  #expect(await second.listed.sorted() == ["/notes/a/deep", "/notes/b"])
  await restored.stop()
}

@Test func cappedPlacesRespectDepthAndRefreshFromBrowsing() async throws {
  let store = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: store) }
  let files = SearchFixture([
    "/home": ["a/"], "/home/a": ["b/"], "/notes": ["a/", "b/", "first", "second"],
  ])
  let index = NameIndex(
    files: files, directory: store, profile: Profile(host: "test.invalid", account: "reader"),
    fingerprint: "key", home: "/home", pins: ["/notes"], fileLimit: 1, folderLimit: 1)
  await index.prepare(deferred: false)
  let result = try await finished(index, "first")
  #expect(result.0.map(\.id) == ["/notes/first"])
  #expect(result.1 == NameIndex.limitNotice)
  #expect(await files.listed.sorted() == ["/home", "/home/a", "/notes", "/notes/a"])
  await index.observed(
    .init(rows: [.init(name: "replacement", stamp: .init(directory: false))], truncated: false),
    folder: "/notes")
  #expect(try await finished(index, "first").0.isEmpty)
  #expect(try await finished(index, "replacement").0.count == 1)
  await index.stop()
}

@Test func cacheIdentityAndOfflineRemoval() async throws {
  let store = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: store) }
  let host = Profile(host: "test.invalid", account: "reader")
  func walk(_ profile: Profile, _ key: String) async throws -> [String] {
    let files = SearchFixture(["/notes": ["note"]])
    let index = NameIndex(
      files: files, directory: store, profile: profile, fingerprint: key, home: "/home",
      pins: ["/notes"])
    await index.prepare(deferred: true)
    #expect(try await finished(index, "note").0.count == 1)
    await index.stop()
    return await files.listed
  }
  #expect(try await walk(host, "one").count == 2)
  #expect(try await walk(host, "one").isEmpty)
  #expect(try await walk(host, "two").count == 2)
  var other = host
  other.account = "another"
  #expect(try await walk(other, "one").count == 2)
  var prefs = Preferences()
  prefs.hosts = [host]
  prefs.homeFolders = [host.id: "/home"]
  NameIndex.prune(directory: store, choices: prefs)
  #expect(try await walk(host, "one") == ["/notes"])
  prefs.set(fileSearchPlugin, for: host.id, enabled: false)
  NameIndex.prune(directory: store, choices: prefs)
  #expect(try await walk(host, "one").count == 2)
  prefs.hosts = []
  NameIndex.prune(directory: store, choices: prefs)
  #expect(try FileManager.default.contentsOfDirectory(atPath: store.path).isEmpty)
}

@Test func refreshDropsNamesUnderUnreadableFolders() async throws {
  let store = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: store) }
  let host = Profile(host: "test.invalid", account: "reader")
  let files = SearchFixture(["/home": ["drafts/", "note.md"], "/home/drafts": ["old-note.md"]])
  func makeIndex() -> NameIndex {
    NameIndex(
      files: files, directory: store, profile: host, fingerprint: "pin", home: "/home", pins: [])
  }
  let first = makeIndex()
  await first.prepare(deferred: false)
  #expect(try await finished(first, "note").0.count == 2)
  await first.stop()

  await files.denyListing("/home/drafts")
  let refreshed = makeIndex()
  await refreshed.prepare(deferred: false, now: Date().addingTimeInterval(901))
  #expect(try await finished(refreshed, "note").0.map(\.id) == ["/home/note.md"])
  await refreshed.stop()
  let restored = makeIndex()
  await restored.prepare(deferred: true)
  #expect(try await finished(restored, "old-note").0.isEmpty)
  await restored.stop()
}

@Test func replacingDirectoryReleasesItsSearchBudget() async throws {
  let store = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: store) }
  let files = SearchFixture(["/home": ["drafts/"], "/home/drafts": ["old.md"]])
  let index = NameIndex(
    files: files, directory: store, profile: Profile(host: "test.invalid", account: "reader"),
    fingerprint: "pin", home: "/home", pins: [], fileLimit: 1)
  await index.prepare(deferred: false)
  #expect(try await finished(index, "old.md").0.count == 1)
  await index.observed(
    .init(rows: [.init(name: "new.md", stamp: .init(directory: false))], truncated: false),
    folder: "/home")
  let (hits, status) = try await finished(index, ".md")
  #expect(hits.map(\.id) == ["/home/new.md"])
  #expect(status == nil)
  await index.stop()
}

@Test(arguments: [SFTPError.closed, .handleLimit])
func checkingProgressDoesNotRetryAnInterruptedWalk(_ interruption: SFTPError) async throws {
  let store = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: store) }
  let files = SearchFixture(["/home": ["note.md"]])
  let index = NameIndex(
    files: files, directory: store, profile: Profile(host: "test.invalid", account: "reader"),
    fingerprint: "pin", home: "/home", pins: [])
  await files.interrupt(with: interruption)
  await index.prepare(deferred: true)
  let (revision, partial, status) = try #require(
    await index.results("note", visits: [], since: nil, waitForIndex: true))
  #expect(partial.isEmpty && status == nil)
  let poll = await index.results("note", visits: [], since: revision, waitForIndex: true)
  #expect(poll == nil)
  #expect(await files.listed == ["/home"])
  await files.interrupt(with: nil)
  #expect(try await finished(index, "note").0.map(\.id) == ["/home/note.md"])
  await index.stop()
}

@Test func namesRankPrefixesWordsTitlesAndReadPaths() {
  let paths = ["café/z", "decafeteria", "big-cafe", "cafes", "read/café.md", "x"]
  func hits(_ query: String, _ paths: [String]) -> [String] {
    let candidates = paths.map { path in
      NameMatcher.Candidate(
        path: "/" + path, relative: path, rootLabel: nil,
        entry: .init(name: (path as NSString).lastPathComponent, directory: false))
    }
    return NameMatcher.matches(
      query, candidates: candidates, titles: ["/read/café.md": "Memo", "/x": "Café society"]
    ).map(\.id)
  }
  #expect(
    hits("CAFE", paths) == [
      "/x", "/read/café.md", "/cafes", "/big-cafe", "/decafeteria", "/café/z",
    ])
  #expect(hits("read memo", paths) == ["/read/café.md"])
  #expect(hits("cafe", (1...35).map { "cafe-\($0)" }).count == 30)
}

private actor PageTrafficFixture: RemoteFiles {
  var events: [String] = []
  func home() -> String { "/" }
  func resolve(_ path: String) -> String { path }
  func stat(_ path: String) -> FileStamp { .init(directory: false) }
  func list(_ path: String) async throws -> [FileRow] {
    events.append("listing began")
    let deadline = ContinuousClock.now + .seconds(2)
    while !events.contains("page began"), .now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    try await NameIndex.walker?.yieldToPages()
    events.append("listing continued")
    return []
  }
  func read(_ path: String, limit: Int) async throws -> Data {
    events.append("page began")
    try await Task.sleep(for: .milliseconds(30))
    events.append("page finished")
    return Data()
  }
}

@Test func listingYieldsToForegroundPage() async throws {
  let store = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: store) }
  let base = PageTrafficFixture()
  let index = NameIndex(
    files: base, directory: store, profile: Profile(host: "test.invalid", account: "reader"),
    fingerprint: "pin", home: "/", pins: [])
  await index.prepare(deferred: false)
  let deadline = ContinuousClock.now + .seconds(2)
  while await base.events.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(2)) }
  let visible = IndexedFiles(base: base, index: index)
  _ = try await visible.read("/note", limit: 32)
  _ = try await finished(index, "note")
  #expect(
    await base.events == ["listing began", "page began", "page finished", "listing continued"])
  await index.stop()
}

@Test(.timeLimit(.minutes(1))) @MainActor func selectedSearchHitOpensAndHostOverrideRemovesIndex() async throws {
  let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let demo = try DemoHost()
  let cache = directory.appending(path: "cache")
  let core = try MobileComposition(directory: directory, cache: cache, keys: DemoKeys()) {
    _, _, _ in demo
  }
  let profile = try await demo.install(in: core)
  let demand = try #require(core.runtime.service(Demand.self))
  let readers = core.runtime.port(Readers.self, realm: profile.realm)
  demand.show(profile.id, in: UUID())
  for await ready in readers.$value.map({ @Sendable in $0 != nil }).values where ready { break }
  let index = try #require(core.runtime.service(FileSearch.self, realm: profile.realm))
  let hit = try #require(try await finished(index, "session 18").0.first)
  let reader = try #require(core.runtime.service(Readers.self, realm: profile.realm))
  #expect(try await reader.open(hit.id).title == "Session notes")
  let prefs = try #require(core.runtime.service(Profiles.self))
  try prefs.update { $0.set(fileSearchPlugin, for: profile.id, enabled: false) }
  await core.runtime.settled()
  #expect(core.runtime.service(FileSearch.self, realm: profile.realm) == nil)
  #expect(core.runtime.service(Files.self, realm: profile.realm) != nil)
  #expect(
    !FileManager.default.fileExists(
      atPath: cache.appending(path: "file-search").appending(path: profile.id.uuidString).path))
  await core.runtime.shutdown()
}
