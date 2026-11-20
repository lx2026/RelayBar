import Foundation
import Testing

@testable import MobileCore

private actor SearchFixture: RemoteFiles {
  var listed: [String] = []
  let folders: [String: [FileRow]]
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
  let deadline = ContinuousClock.now + .seconds(3)
  repeat {
    if let (_, hits, status) = await index.results(query, visits: [], since: nil),
      status?.hasPrefix("Indexing") != true
    {
      return (hits, status)
    }
    try await Task.sleep(for: .milliseconds(5))
  } while .now < deadline
  Issue.record("The index did not finish: \(await index.diagnostics)")
  throw CocoaError(.fileReadUnknown)
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

@Test @MainActor func selectedSearchHitOpensAndHostOverrideRemovesIndex() async throws {
  let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let demo = try DemoHost()
  let cache = directory.appending(path: "cache")
  let core = try MobileComposition(directory: directory, cache: cache, keys: DemoKeys()) {
    _, _, _ in demo
  }
  let profile = try await demo.install(in: core)
  core.runtime.service(Demand.self)?.show(profile.id, in: UUID())
  let deadline = ContinuousClock.now + .seconds(3)
  while core.runtime.service(FileSearch.self, realm: profile.realm) == nil, .now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
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
