import Composition
import CryptoKit
import Foundation
import HouseStyle
import MarkdownRendering
import RelayTransport
import Testing

@testable import MobileCore

private actor InitiallyLockedKeys: KeyProvider {
  let privateKey: P256.Signing.PrivateKey
  var locked = true
  init(_ key: P256.Signing.PrivateKey) { privateKey = key }
  func unlock() { locked = false }
  func existingKey() throws -> DeviceKey? { try key() }
  func key() throws -> DeviceKey {
    guard !locked else { throw KeychainReadError.locked }
    return .memory(privateKey)
  }
}

private actor FakeFiles: RemoteFiles {
  var content = Data("# Original".utf8)
  var modified: UInt32 = 1
  var reads = 0
  func change() {
    content = Data("# Modified".utf8)
    modified += 1
  }
  func home() -> String { "/" }
  func resolve(_ path: String) -> String {
    path == "/notes/link.png" ? "/elsewhere/picture.png" : path
  }
  func list(_ path: String) -> [FileRow] { [] }
  func stat(_ path: String) -> FileStamp {
    .init(size: UInt64(content.count), modified: modified, directory: false)
  }
  func read(_ path: String, limit: Int) throws -> Data {
    guard ["/notes/report.md", "/notes/art.png"].contains(path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    reads += 1
    return content
  }
}

private struct FakeConnection: HostConnection {
  let remote: FakeFiles
  func files() async throws -> any RemoteFiles { remote }
  let stream: AsyncStream<ConnectionEvent>
  func run(_ publish: @escaping @MainActor @Sendable (ConnectionEvent) -> Void) async {
    for await event in stream { await publish(event) }
  }
  func suspend() async {}
}

@MainActor private func waitFor<T>(_ value: () -> T?) async throws -> T {
  let until = ContinuousClock.now + .seconds(15)
  while ContinuousClock.now < until {
    if let value = value() { return value }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw CompositionError("Timed out waiting for the feature.")
}

@Test @MainActor func compositionAndHistory() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let remote = FakeFiles()
  let (stream, events) = AsyncStream<ConnectionEvent>.makeStream()
  let core = try MobileComposition(directory: folder, cache: folder.appending(path: "cache")) {
    _, _, _ in
    FakeConnection(remote: remote, stream: stream)
  }
  do {
    await core.runtime.settled()
    let prefs = try #require(core.runtime.service(Profiles.self))
    let profile = Profile(host: "example.invalid", account: "reader")
    let pins = try #require(core.runtime.service(Trust.self))
    try pins.update {
      $0[profile.id.uuidString] = .init(algorithm: "test", fingerprint: "test-pin")
    }
    try prefs.update {
      $0.hosts.append(profile)
      $0.lastHost = profile.id
    }
    let demand = try #require(core.runtime.service(Demand.self))
    let first = UUID()
    let second = UUID()
    #expect(core.runtime.status(profile.realm) == nil)
    demand.show(profile.id, in: first)
    demand.show(profile.id, in: second)
    await core.runtime.settled()
    events.yield(.ready)
    let port = core.runtime.port(Readers.self, realm: profile.realm)
    let reader = try await waitFor { port.value }
    let featureIDs = core.runtime.statuses.map(\.id)
    let doc = try await reader.open("/notes/report.md")
    #expect(doc.title == "Original")
    let position = ReadingPosition(heading: "Original", offset: 18, absoluteOffset: 50)
    try reader.save(position: position, path: doc.path)
    events.yield(.lost)
    _ = try await waitFor { port.value == nil ? true : nil }
    #expect(core.runtime.service(Files.self, realm: profile.realm) == nil)
    events.yield(.ready)
    let recovered = try await waitFor { port.value }
    let reopened = try await recovered.open(doc.path)
    #expect(reopened.position == position)
    #expect(await remote.reads == 1)
    await remote.change()
    let changed = try await recovered.open(doc.path)
    #expect(changed.changed && changed.title == "Modified")
    demand.show(nil, in: first)
    #expect(port.value != nil)
    demand.show(nil, in: second)
    await core.runtime.settled()
    #expect(core.runtime.status(profile.realm) == nil)
    let restart = try MobileComposition(directory: folder, cache: folder.appending(path: "cache"))
    do {
      await restart.runtime.settled()
      let history = try #require(restart.runtime.service(Profiles.self)?.value.history)
      #expect(history.count == 1 && history[0].position == position)
      #expect(try await restart.savedDocument(doc.path, profile: profile)?.title == "Modified")
      try await restart.cache.clear(profile.id)
      #expect(try await restart.savedDocument(doc.path, profile: profile) == nil)
      for file in try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil)
      where file.lastPathComponent.contains(".json") {
        let json = try String(contentsOf: file, encoding: .utf8)
        for id in featureIDs {
          #expect(!json.contains("\"" + id + "\""))
        }
      }
    } catch {
      await restart.runtime.shutdown()
      throw error
    }
    await restart.runtime.shutdown()
  } catch {
    await core.runtime.shutdown()
    throw error
  }
  await core.runtime.shutdown()
}

@Test func identityAndAssets() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let cache = DocumentCache(directory: folder)
  let files = FakeFiles()
  let profile = UUID()
  let key = CacheIdentity(
    profile: profile, account: "reader", fingerprint: "one", path: "/notes/report.md")
  _ = try await cache.load(key, files: files, limit: 200)
  for other in [
    CacheIdentity(
      profile: UUID(), account: key.account, fingerprint: key.fingerprint, path: key.path),
    .init(profile: profile, account: "another", fingerprint: key.fingerprint, path: key.path),
    .init(profile: profile, account: key.account, fingerprint: "two", path: key.path),
    .init(
      profile: profile, account: key.account, fingerprint: key.fingerprint, path: "/another.md"),
  ] {
    #expect(await cache.cached(other) == nil)
  }
  let assets = AssetFolder(document: key.path, files: files)
  #expect(try await assets.read(relative: "art.png") == files.content)
  for invalid in ["../art.png", "/art.png", "link.png", "art.html"] {
    await #expect(throws: (any Error).self) { try await assets.read(relative: invalid) }
  }
}

#if os(macOS)
  @Test func macReaderFixtures() async throws {
    let apps = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    for name in ["ordinary", "extended"] {
      let data = try Data(
        contentsOf: apps.appending(
          path: "Frame/Tests/FrameKitTests/Fixtures/markdown/" + name + ".md"))
      let doc = try await Format.markdown.render(
        path: name + ".md",
        file: .init(
          stamp: .init(size: UInt64(data.count), modified: 1, directory: false),
          data: data, date: Date()), token: "snapshot")
      let references = apps.deletingLastPathComponent().appending(
        path: "Packages/AppComposition/Tests/MarkdownRenderingTests/ReferencePages")
      let reference = try String(
        contentsOf: references.appending(path: name + ".html"), encoding: .utf8)
      // Frame preserves the relative image where the standalone preview uses a placeholder.
      let expected = reference.replacingOccurrences(
        of: "<strong>Image not loaded:</strong> Colour bands from the run",
        with: #"<img src="diagram.png" alt="Colour bands from the run" />"#)
      func markup(_ value: String) -> String {
        value.replacingOccurrences(
          of: #"data:image/png;base64,[A-Za-z0-9+/=]+"#, with: "math-png",
          options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let actual = try #require(doc.html?.components(separatedBy: "</style>").last)
      #expect(markup(actual) == markup(expected))
    }
  }

  @Test @MainActor func openSSHContinueReading() async throws {
    let server = try OpenSSHFixture()
    defer { server.cleanup() }
    try await server.start()
    let url = server.folder.appending(path: "report.md")
    try Data("# Fixture report\n\nParagraph.".utf8).write(to: url)
    let linked = server.folder.appending(path: "linked-directory")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: server.folder)
    let store = server.folder.appending(path: "mobile")
    let cache = server.folder.appending(path: "cache")
    let keys = InitiallyLockedKeys(server.signingKey)
    let core = try MobileComposition(directory: store, cache: cache, keys: keys)
    let profile = Profile(host: "127.0.0.1", account: NSUserName(), port: server.port)
    let scene = UUID()
    do {
      await core.runtime.settled()
      let prefs = try #require(core.runtime.service(Profiles.self))
      try prefs.update {
        $0.hosts.append(profile)
        $0.lastHost = profile.id
      }
      core.runtime.service(Demand.self)?.show(profile.id, in: scene)
      let auth = try await waitFor {
        core.runtime.service(AuthenticationPort.self, realm: profile.realm)
      }
      _ = try await waitFor { auth.prompt }
      try auth.trust()
      let failure = try await waitFor {
        if case .failed(let reason) = core.states.values[profile.id] { return reason }
        return nil
      }
      #expect(failure == KeychainReadError.locked.localizedDescription)
      await keys.unlock()
      try core.retry(profile.id)
      let reader = try await waitFor { core.runtime.service(Readers.self, realm: profile.realm) }
      let files = try #require(core.runtime.service(Files.self, realm: profile.realm))
      #expect(
        try await files.home()
          == files.resolve(FileManager.default.homeDirectoryForCurrentUser.path))
      #expect(try await files.list(server.folder.path).contains { $0.name == "report.md" })
      #expect(
        try await files.list(server.folder.path).first { $0.name == "linked-directory" }?.stamp
          .directory == true)
      let session = try #require(core.runtime.service(Session.self, realm: profile.realm))
      let upstream = core.runtime.port(WebUpstream.self, realm: profile.realm)
      let generation = upstream.generation
      await session.networkPathChanged()
      #expect(upstream.generation == generation)
      let large = server.folder.appending(path: "listing")
      try FileManager.default.createDirectory(at: large, withIntermediateDirectories: false)
      for i in 0...10_000 { try Data().write(to: large.appending(path: String(i))) }
      let listing = try await files.listing(large.path)
      #expect(listing.rows.count == 10_000)
      #expect(listing.notice == "Showing the first 10,000 items")
      let small = try await files.listing(server.folder.path)
      #expect(small.notice.isEmpty)
      let logURL = server.folder.appending(path: "progress.log")
      try Data("First\n".utf8).write(to: logURL)
      let initial = try await files.list(server.folder.path)
      let remove = try #require(initial.first { $0.name == "progress.log" }?.remove)
      #expect(initial.first { $0.name == "linked-directory" }?.remove == nil)
      var cursor = LogCursor()
      try await cursor.poll(logURL.path, files: files)
      #expect(cursor.text == "First\n")
      let handle = try FileHandle(forWritingTo: logURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("Next\n".utf8))
      try handle.close()
      try await cursor.poll(logURL.path, files: files)
      #expect(cursor.text == "First\nNext\n")
      await #expect(throws: (any Error).self) { try await remove() }
      try Data("New".utf8).write(to: logURL, options: .atomic)
      try await cursor.poll(logURL.path, files: files)
      try await cursor.poll(logURL.path, files: files)
      #expect(cursor.text == "New")
      let refreshed = try await files.list(server.folder.path)
      let currentRemoval = try #require(refreshed.first { $0.name == "progress.log" }?.remove)
      try await currentRemoval()
      #expect(!FileManager.default.fileExists(atPath: logURL.path))
      let source = try MediaSource(
        path: url.path, stamp: try await files.stat(url.path), files: files)
      let bytes = try Data(contentsOf: url)
      for offset in [0, 4, 12, 1] {
        #expect(
          try await source.read(offset: Int64(offset), length: 4, interactive: true)
            == bytes[offset..<offset + 4])
      }
      #expect(try await reader.open(url.path).title == "Fixture report")
    } catch {
      await core.runtime.shutdown()
      throw error
    }
    await core.runtime.shutdown()
    let restart = try MobileComposition(directory: store, cache: cache, keys: keys)
    do {
      await restart.runtime.settled()
      let restored = try #require(restart.runtime.service(Profiles.self)?.value)
      #expect(restored.lastHost == profile.id)
      let visit = try #require(restored.history.first)
      restart.runtime.service(Demand.self)?.show(restored.lastHost, in: scene)
      let next = try await waitFor { restart.runtime.service(Readers.self, realm: profile.realm) }
      #expect(try await next.open(visit.path).title == visit.title)
    } catch {
      await restart.runtime.shutdown()
      throw error
    }
    await restart.runtime.shutdown()
  }
#endif

@Test @MainActor func trustAndPreferenceVersion() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let profile = Profile(host: "example.invalid", account: "reader")
  let pins = PreferenceStore<[String: Identity]>(
    url: folder.appending(path: "trust.json"), initial: [:])
  try pins.load()
  let key = Identity(algorithm: "test", fingerprint: "first")
  let auth = SignIn(profile, pins)
  let first = Task { await auth.verify(key) }
  _ = try await waitFor { auth.prompt }
  #expect(pins.value.isEmpty)
  auth.cancel()
  #expect(await first.value == false)
  let next = SignIn(profile, pins)
  let second = Task { await next.verify(key) }
  _ = try await waitFor { next.prompt }
  try next.trust()
  #expect(await second.value)
  #expect(await next.verify(key))
  #expect(await next.verify(.init(algorithm: "test", fingerprint: "changed")) == false)
  #expect(next.prompt == nil)
  let url = folder.appending(path: "preferences.json")
  let future = Data(#"{"version":99,"preferences":{}}"#.utf8)
  try future.write(to: url)
  #expect(throws: (any Error).self) {
    try MobileComposition(directory: folder, cache: folder.appending(path: "cache"))
  }
  #expect(try Data(contentsOf: url) == future)
}

@Test func schemeServesDocumentAndAssets() async throws {
  let host = try DemoHost()
  let scheme = DocumentScheme(path: DemoHost.folder + "/notes/comparison.md")
  let (main, data) = try await scheme.response(
    for: scheme.mainURL, html: "<article>Test</article>", files: host)
  #expect(
    main.mimeType == "text/html"
      && String(decoding: data, as: UTF8.self) == "<article>Test</article>")
  for (relative, mime) in [
    ("../samples/grid-0031.png", "image/png"), ("../metrics.json", "application/json"),
    ("../notes.txt", "text/plain"),
  ] {
    let url = try #require(URL(string: relative, relativeTo: scheme.mainURL)?.absoluteURL)
    let (response, bytes) = try await scheme.response(for: url, html: "", files: host)
    #expect(response.mimeType == mime && !bytes.isEmpty)
  }
  let foreign = try #require(URL(string: "https://example.invalid/report.md"))
  await #expect(throws: URLError.self) {
    try await scheme.response(for: foreign, html: "", files: host)
  }
  await #expect(throws: (any Error).self) {
    try await AssetFolder(document: "/doc.md", files: host).read(relative: "../report.md")
  }
}

@Test func budgetEvictsLeastRecentlyUsedAndSurvivesRestart() async throws {
  let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let files = FakeFiles()
  let size = await files.content.count
  let cache = DocumentCache(directory: dir, budget: 2 * size)
  let keys = (0..<3).map {
    CacheIdentity(
      profile: UUID(), account: "reader", fingerprint: String($0), path: "/notes/report.md")
  }
  for key in keys.prefix(2) { _ = try await cache.load(key, files: files, limit: size) }
  #expect(await cache.cached(keys[0]) != nil)
  _ = try await cache.load(keys[2], files: files, limit: size)
  let reopened = DocumentCache(directory: dir, budget: 2 * size)
  #expect(await reopened.cached(keys[0]) != nil)
  #expect(await reopened.cached(keys[1]) == nil)
  #expect(await reopened.cached(keys[2]) != nil)
}

@Test func failedCacheWriteStillOpensTheDocument() async throws {
  let blocker = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: blocker) }
  // A regular file where the cache folder should be makes every cache write fail.
  try Data().write(to: blocker)
  let files = FakeFiles()
  let size = await files.content.count
  let cache = DocumentCache(directory: blocker)
  let key = CacheIdentity(
    profile: UUID(), account: "reader", fingerprint: "test", path: "/notes/report.md")
  let file = try await cache.load(key, files: files, limit: size)
  #expect(file.data.count == size)
  #expect(await cache.cached(key) == nil)
}

@Test @MainActor func queuedTrustCannotReplacePinOrStrandWaiter() async throws {
  let pins = PreferenceStore<[String: Identity]>(url: nil, initial: [:])
  try pins.load()
  let auth = SignIn(Profile(host: "example.invalid", account: "reader"), pins)
  let key = Identity(algorithm: "test", fingerprint: "one")
  let a = Task { await auth.verify(key) }
  _ = try await waitFor { auth.prompt }
  let b = Task { await auth.verify(.init(algorithm: "test", fingerprint: "two")) }
  await Task.yield()
  try auth.trust()
  #expect(await a.value)
  #expect(await b.value == false)
  #expect(auth.prompt == nil)
}

@Test func messagesAndEndpoints() throws {
  let errors: [TransportError] = [
    .unreachable, .hostKeyRefused, .hostKeyChanged(.init(type: "test", fingerprint: "changed")),
    .signInRefused([]), .algorithmMismatch([]), .sftpUnavailable, .forwardingProhibited,
    .connectionRefused, .cancelled, .invalidEndpoint, .disconnected,
  ]
  let messages = errors.map { $0.message(for: "example.invalid") }
  #expect(Set(messages).count == errors.count)
  #expect(messages.filter { $0.contains("Tailscale") }.count == 1)
  for value in ["ssh -p 2222 reader@host", "reader@host:2222"] {
    let endpoint = try HostEndpoint(value)
    #expect(endpoint.account == "reader" && endpoint.host == "host" && endpoint.port == 2222)
  }
  #expect(try HostEndpoint("host").account == nil)
  #expect(try HostEndpoint("reader@host").port == 22)
}

@Test @MainActor func contributionsFollowTheirHostRealm() async throws {
  let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let demo = try DemoHost()
  let core = try MobileComposition(directory: dir, cache: dir.appending(path: "cache")) { _, _, _ in
    demo
  }
  do {
    let profile = try await demo.install(in: core)
    core.runtime.service(Demand.self)?.show(profile.id, in: UUID())
    let reader = try await waitFor { core.runtime.service(Readers.self, realm: profile.realm) }
    let prefs = try #require(core.runtime.service(Profiles.self))
    let doc = try await reader.open(DemoHost.image)
    #expect(doc.details["Prompt"]?.contains("poster") == true)
    let locations = try #require(core.runtime.service(Locations.self, realm: profile.realm))
    let actions = try #require(core.runtime.service(FileActions.self, realm: profile.realm))
    let sections = try #require(core.runtime.service(Sections.self, realm: profile.realm))
    let fav = try #require(actions.entries.first { $0.id == "favourite" })
    let places = prefs.value.places(for: profile.id).map(\.path)
    try fav.perform(doc.path) {}
    #expect(prefs.value.places(for: profile.id).map(\.path) == places + [doc.path])
    #expect(
      sections.entries.sorted { $0.order < $1.order }.map(\.id) == [
        "continue", "places", "recent", "services",
      ])
    #expect(
      locations.entries.first { $0.id == "prompt" }?.resolve("prompt:poster") == .path(doc.path))
    #expect(
      [0, DocumentCache.thumbnailSourceLimit].contains(
        core.runtime.service(ThumbnailLimit.self, realm: profile.realm) ?? -1)
    )
    #expect(core.runtime.service(Formats.self)?.descriptor(for: "report.ipynb") != nil)
    #expect(core.runtime.service(Formats.self)?.descriptor(for: "report.tsv") != nil)
    #expect(core.runtime.service(Pages.self)?.entries.count == 6)
    #expect(core.runtime.service(PaperSurface.self) == .paper)
    #expect(core.runtime.service(Formats.self)?.descriptor(for: "file.json") != nil)
    try prefs.update { value in
      for option in MobileComposition.plugins { value.plugins.set(option, enabled: false) }
    }
    await core.runtime.settled()
    #expect(core.runtime.service(PaperSurface.self) == nil)
    #expect(prefs.value.places(for: profile.id).isEmpty)
    #expect(!locations.entries.contains { $0.id == "prompt" })
    #expect(!actions.entries.contains { $0.id == "favourite" })
    #expect(core.runtime.service(ThumbnailLimit.self, realm: profile.realm) == nil)
    #expect(core.runtime.service(Formats.self)?.descriptor(for: "report.ipynb") == nil)
    #expect(core.runtime.service(Formats.self)?.descriptor(for: "report.tsv")?.id == "text")
  } catch {
    await core.runtime.shutdown()
    throw error
  }
  await core.runtime.shutdown()
}

@Test func compressedPNGText() throws {
  let data = try #require(
    Data(
      base64Encoded:
        "iVBORw0KGgoAAAAUelRYdEF1dGhvcgAAeJxLTkx7CQAEaAIUZHoqJgAAAB1pVFh0UHJvbXB0AAEAZW4AAHicS8opTVV4tnU7ABAWBBtRURDvAAAAAElFTkSuQmCC"
    ))
  #expect(PNGTextReader.read(data: data) == ["Author": "café", "Prompt": "blue 海"])
}

@Test @MainActor func passwordAndTrustRequestsShareAQueue() async throws {
  let pins = PreferenceStore<[String: Identity]>(url: nil, initial: [:])
  try pins.load()
  let auth = SignIn(
    Profile(host: "example.invalid", account: "reader"), pins, savedPassword: { _ in nil })
  let password = Task { try await auth.password() }
  _ = try await waitFor { auth.prompt }
  let identity = Identity(algorithm: "test", fingerprint: "key")
  let trust = Task { await auth.verify(identity) }
  await Task.yield()
  #expect(auth.prompt == .password)
  try auth.submit("fixture", remember: false)
  #expect(try await password.value == "fixture")
  _ = try await waitFor { auth.prompt == .trust(identity) ? true : nil }
  let second = Task { try await auth.password() }
  await Task.yield()
  auth.cancel()
  #expect(await trust.value == false)
  await #expect(throws: CancellationError.self) { try await second.value }
}

@Test @MainActor func compositionRootReleasesWhileRuntimeLives() async throws {
  let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  var core: MobileComposition? = try MobileComposition(
    directory: directory, cache: directory.appending(path: "cache"))
  let runtime = try #require(core?.runtime)
  await runtime.settled()
  let released = { [weak core] in core == nil }
  core = nil
  #expect(released())
  await runtime.shutdown()
}

@Test func cachedThumbnailNeedsNoSecondTransfer() async throws {
  let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = DocumentCache(directory: directory)
  let demo = try DemoHost()
  let key = CacheIdentity(
    profile: UUID(), account: "reader", fingerprint: "test", path: DemoHost.image)
  let stamp = try demo.stat(key.path)
  let thumbnail = try #require(
    try await cache.thumbnail(key, files: demo, stamp: stamp, limit: 2 << 20))
  // This service cannot serve the image. A second lookup must use the indexed thumbnail.
  let reopened = DocumentCache(directory: directory)
  #expect(
    try await reopened.thumbnail(key, files: FakeFiles(), stamp: stamp, limit: 2 << 20) == thumbnail
  )
}

@Test func htmlAssetsStayInResolvedDocumentFolder() async throws {
  let files = FakeFiles()
  let page = DocumentScheme(path: "/notes/report.html", folderOnly: true)
  let good = try #require(URL(string: "art.png", relativeTo: page.mainURL)?.absoluteURL)
  _ = try await page.response(for: good, html: "", files: files)
  for target in ["link.png", "../other.png"] {
    let url = try #require(URL(string: target, relativeTo: page.mainURL)?.absoluteURL)
    await #expect(throws: URLError.self) {
      try await page.response(for: url, html: "", files: files)
    }
  }
  #expect(await files.reads == 1)
}

@Test @MainActor func endpointPinsAreSharedAndConflictsNameTheProfile() async throws {
  let owner = Profile(host: "server.example.", account: "first")
  let guest = Profile(host: "SERVER.example", account: "second")
  let key = Identity(algorithm: "test", fingerprint: "one")
  let changed = Identity(algorithm: "test", fingerprint: "two")
  let pins = PreferenceStore<[String: Identity]>(url: nil, initial: [:])
  try pins.load()
  let auth = SignIn(guest, pins, profiles: { [owner, guest] })
  let pending = Task { await auth.verify(changed) }
  _ = try await waitFor { auth.prompt }
  try pins.update { $0[owner.id.uuidString] = key }
  try auth.trust()
  #expect(await pending.value == false)
  #expect(auth.failureReason?.contains(owner.account + "@" + owner.host) == true)
  #expect(auth.prompt == nil && pins.value[guest.id.uuidString] == nil)
  let retry = SignIn(guest, pins, profiles: { [owner, guest] })
  #expect(await retry.verify(key))
  #expect(retry.prompt == nil && pins.value[guest.id.uuidString] == key)
}

@Test @MainActor func lockedCredentialsAndReadOnlyKeyLookup() async throws {
  let keys = EnclaveKeys(read: { _ in nil })
  #expect(try await keys.existingKey() == nil)
  let profile = Profile(host: "host.example", account: "reader")
  let pins = PreferenceStore<[String: Identity]>(url: nil, initial: [:])
  var locked = true
  let auth = SignIn(
    profile, pins,
    savedPassword: { _ in
      if locked { throw KeychainReadError.locked }
      return Data("fixture".utf8)
    })
  await #expect(throws: KeychainReadError.locked) { try await auth.password() }
  #expect(auth.failureReason == KeychainReadError.locked.localizedDescription)
  locked = false
  #expect(try await auth.password() == "fixture")
  let signer = EnclaveKeys(read: { _ in throw KeychainReadError.locked })
  await #expect(throws: KeychainReadError.locked) { try await auth.signingKey(signer) }
}

@Test @MainActor func legacyFavouritesMigrateOnLoad() async throws {
  let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let host = UUID()
  let store = PreferenceStore(
    url: folder.appending(path: "preferences.json"), initial: Preferences())
  try store.load()
  try store.update { $0.favourites = [host: ["/notes/a.md", "/notes/b.md"]] }
  let core = try MobileComposition(
    directory: folder, cache: folder.appending(path: "cache"), keys: DemoKeys())
  await core.runtime.settled()
  let prefs = try #require(core.runtime.service(Profiles.self))
  #expect(prefs.value.places(for: host).map(\.path) == ["/notes/a.md", "/notes/b.md"])
  #expect(prefs.value.favourites == nil)
  let reopened = PreferenceStore(url: store.url, initial: Preferences())
  try reopened.load()
  #expect(reopened.value == prefs.value)
  await core.runtime.shutdown()
}

@Test func unpinningTheCurrentPlaceClearsIt() throws {
  let host = UUID()
  var prefs = Preferences()
  let place = Place(path: "/notes", directory: true)
  prefs.togglePin(place, host: host)
  prefs.select(place, host: host)
  let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
  #expect(saved.currentPlaces?[host] == place.path)
  prefs.togglePin(place, host: host)
  #expect(prefs.currentPlaces?[host] == nil)
}

@Test func locationCompletesHomeAndDescendsIntoFolder() async throws {
  let demo = try DemoHost()
  let source = completePath
  let runs = try #require(try await source("~/ru", nil, demo).first)
  #expect(runs.input == "~/runs/")
  let study = try #require(try await source(runs.input, nil, demo).first)
  let entries = try await source(study.input, nil, demo)
  #expect(entries.first?.place.directory == true)
  #expect(entries.last?.place.directory == false)
  #expect(entries.contains { $0.place.path == DemoHost.report })
}
