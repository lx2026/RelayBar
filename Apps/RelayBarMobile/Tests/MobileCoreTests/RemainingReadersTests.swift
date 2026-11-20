import RelayTransport
import PreviewSupport
import CompositionFixtures
import Foundation
import HouseStyle
import JavaScriptCore
import Testing

@testable import MobileCore
@testable import MobileUI

@Test func mediaRangesAndCancelledSeek() async throws {
  let demo = try DemoHost()
  let path = DemoHost.folder + "/walkthrough.mp4"
  let bytes = try demo.read(path, limit: 300_000)
  let source = try MediaSource(path: path, stamp: demo.stat(path), files: demo)
  for offset in [0, 128, 256, 32] {
    #expect(
      try await source.read(offset: Int64(offset), length: 128, interactive: true)
        == bytes[offset..<offset + 128])
  }
  let seek = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await source.read(offset: 100, length: 200, interactive: true)
  }
  await #expect(throws: CancellationError.self) { try await seek.value }
}

@Test func structuredPreviewFixturesAndLimits() throws {
  let demo = try DemoHost()
  let csv = try demo.read(DemoHost.folder + "/metrics.csv", limit: StructuredPreview.limit)
  #expect(try StructuredPreview.table(csv, delimiter: ",").contains("<th>Template</th>"))
  let tsv = Data("name\tvalue\r\nA\t\"two\nlines \"\"quoted\"\"\"\r\n".utf8)
  #expect(
    try StructuredPreview.table(tsv, delimiter: "\t").contains("two\nlines &quot;quoted&quot;"))
  let notebook = try demo.read(DemoHost.folder + "/study.ipynb", limit: StructuredPreview.limit)
  let page = try StructuredPreview.notebook(notebook)
  #expect(
    page.contains("<strong>48 samples</strong>") && page.contains("preferred")
      && page.contains("<pre>31"))
  let huge = Data(count: StructuredPreview.limit + 1)
  #expect(throws: (any Error).self) { try StructuredPreview.notebook(huge) }
  #expect(throws: (any Error).self) { try StructuredPreview.table(huge, delimiter: ",") }
}

@Test func hostPermissionRoundTrip() throws {
  var first = Profile(host: "one.invalid", account: "reader")
  let second = Profile(host: "two.invalid", account: "reader")
  #expect(!first.allowsInternetResources)
  first.allowsInternetResources = true
  let hosts = try JSONDecoder().decode([Profile].self, from: JSONEncoder().encode([first, second]))
  #expect(hosts.map(\.allowsInternetResources) == [true, false])
}

@Test @MainActor func dataSaverPolicyAndPadRestoration() throws {
  for expensive in [false, true] {
    for constrained in [false, true] {
      #expect(
        TransferPolicy.restrict(enabled: true, expensive: expensive, constrained: constrained)
          == (expensive || constrained))
      #expect(
        !TransferPolicy.restrict(enabled: false, expensive: expensive, constrained: constrained))
    }
  }
  var state = PadSelection()
  let first = Route.document("/report.md")
  let second = Route(kind: "service", path: "http://studio.invalid:6006")
  state.select(first, beside: false)
  state.select(second, beside: true)
  state.sidebarVisible = true
  state.resize(0.67)
  let restored = try JSONDecoder().decode(PadSelection.self, from: JSONEncoder().encode(state))
  #expect(restored.primary == first && restored.beside == second && restored.fraction == 0.67)
  #expect(restored.sidebarVisible == true && restored.treeSelection == second)
  state.select(second, beside: false)
  #expect(state.primary == second && state.beside == nil)
}

private actor PausedRead: RangeFiles {
  let started: AsyncStream<Void>.Continuation
  init(started: AsyncStream<Void>.Continuation) { self.started = started }
  func bytes(_ path: String, range: Range<UInt64>, interactive: Bool) async throws -> Data {
    started.yield()
    try await Task.sleep(for: .seconds(10))
    return Data(count: range.count)
  }
  func home() -> String { "/" }
  func resolve(_ path: String) -> String { path }
  func stat(_ path: String) -> FileStamp { .init(size: 2048, directory: false) }
  func list(_ path: String) -> [FileRow] { [] }
  func read(_ path: String, limit: Int) throws -> Data { throw URLError(.unsupportedURL) }
}

@Test func cancellingAnOutstandingSeek() async throws {
  let (events, started) = AsyncStream<Void>.makeStream()
  let files = PausedRead(started: started)
  let source = try MediaSource(
    path: "/clip.mp4", stamp: await files.stat("/clip.mp4"), files: files)
  let seek = Task { try await source.read(offset: 1024, length: 256, interactive: true) }
  for await _ in events { break }
  seek.cancel()
  await #expect(throws: CancellationError.self) { try await seek.value }
}

@Test(arguments: CompanionGroupingFixture.all)
func folderRowsKeepCompanionsWithTheirOwner(_ fixture: CompanionGroupingFixture) {
  let stamp = FileStamp(size: 32, directory: false)
  let rows = groupedRows(fixture.files.map { FileRow(name: $0, stamp: stamp) })
  let companions = Set(fixture.groups.values.flatMap { $0 })
  #expect(rows.map(\.name) == fixture.files.filter { !companions.contains($0) })
  for row in rows {
    #expect(row.companions == fixture.groups[row.name, default: []])
  }
}

@Test @MainActor func plainTextUsesReaderPaper() {
  for form in [HouseForm.paper, .standard] {
    let html = plainTextPage("<source>", form: form)
    for dark in [false, true] {
      #expect(html.contains("--md-bg:" + HousePalette.paper.css(in: form, dark: dark)))
    }
    #expect(html.contains("<pre>&lt;source&gt;</pre>"))
  }
}

@Test func imagePromptOmitsWorkflowGraph() async throws {
  // One gray pixel with a tEXt chunk containing a node graph under the key Prompt.
  let encoded =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAM3RFWHRQcm9tcHQAIAp7IjEi"
      + "OnsiY2xhc3NfdHlwZSI6IlNhbXBsZXIiLCJpbnB1dHMiOnt9fX1joL4HAAAACklEQVR4nGNo"
      + "AAAAggCBd81ytgAAAABJRU5ErkJggg=="
  let png = try #require(Data(base64Encoded: encoded))
  var doc = try await Format.image.render(
    path: "/image.png",
    file: .init(stamp: .init(size: UInt64(png.count), directory: false), data: png, date: Date()))
  #expect(doc.details["Prompt"]?.contains("class_type") == true)
  #expect(doc.imagePrompt == nil)
  doc.details["Prompt"] = #"{"nodes":[],"links":[]}"#
  #expect(doc.imagePrompt == nil)
  doc.details["Prompt"] = "A bird on a branch"
  #expect(doc.imagePrompt == "A bird on a branch")
}

@Test func sceneAndTabStorageStripServiceSecrets() throws {
  let route = Route(
    kind: "service",
    path:
      "http://fixture-user:fixture-password@page.example:8123/report?token=fixture-cookie#fragment")
  let scene = PadSelection(primary: route, beside: route, previous: [route], forward: [route])
  var prefs = Preferences()
  let address = ServiceAddress(port: 8123, path: "/report?token=fixture-cookie#fragment")
  prefs.open(address, host: UUID())
  prefs.pinnedServices = [UUID(): [address]]
  for data in [try JSONEncoder().encode(scene), try JSONEncoder().encode(prefs)] {
    let encoded = String(decoding: data, as: UTF8.self)
    for secret in [
      "?", "#", "fixture-user", "fixture-password", "token", "fixture-cookie", "fragment",
    ] {
      #expect(!encoded.contains(secret))
    }
    #expect(encoded.contains("report"))
  }
  // A scene written before sanitising is cleaned when it is read back.
  let old = Data(
    #"{"primary":{"kind":"service","path":"http://fixture-user:fixture-password@page.example:8123/report?token=fixture-cookie#fragment"},"fraction":0.5,"previous":[],"forward":[]}"#
      .utf8)
  let restored = try JSONDecoder().decode(PadSelection.self, from: old)
  #expect(restored.primary?.path == "http://page.example:8123/report")
}

@Test func thumbnailsBoundReadsAndKeepOriginalOutOfCache() async throws {
  let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let cache = DocumentCache(directory: root)
  let demo = try DemoHost()
  let key = CacheIdentity(
    profile: UUID(), account: "reader", fingerprint: "fixture", path: DemoHost.image)
  let stamp = try demo.stat(key.path)
  var large = stamp
  large.size = (20 << 20) + 1
  #expect(try await cache.thumbnail(key, files: demo, stamp: large, limit: 100 << 20) == nil)
  #expect(try await cache.thumbnail(key, files: demo, stamp: stamp, limit: 20 << 20) != nil)
  #expect(await cache.cached(key) == nil)
  #expect(try await cache.thumbnail(key, files: demo, stamp: stamp, limit: 0) == nil)
}

@Test func canvasMarksTheFolderAndExpiresAfterTenMinutes() {
  var scene = PadSelection()
  #expect(scene.primary == nil && scene.markedFolder == nil)
  scene.select(.folder("/notes"), beside: false)
  #expect(scene.markedFolder == "/notes")
  scene.select(.document("/other/report.md"), beside: false)
  #expect(scene.markedFolder == "/other")
  scene.select(.init(kind: "service", path: "http://studio.invalid:8000"), beside: true)
  #expect(scene.markedFolder == nil)
  #expect(PadSelection.restores(100, now: 699))
  #expect(!PadSelection.restores(100, now: 700))
  #expect(!PadSelection.restores(0, now: 100))
}

@Test func hiddenCountsAndSiblingOrderUseTheFolderListing() {
  func file(_ name: String, _ time: UInt32) -> FileRow {
    .init(name: name, stamp: .init(modified: time, directory: false))
  }
  let rows = [file("10.md", 2), file(".old", 0), file("2.md", 2), file("a.txt", 3)]
  #expect(FolderListing.split(rows, name: \.name).hidden == 1)
  let visible = rows.filter { !$0.name.hasPrefix(".") }
  #expect(sortedFolderFiles(visible, order: .modified).map(\.name) == ["a.txt", "2.md", "10.md"])
  #expect(sortedFolderFiles(visible, order: .name).map(\.name) == ["2.md", "10.md", "a.txt"])
}

private actor PreviewFiles: RangeFiles {
  var ranges: [Range<UInt64>] = []
  var revision: UInt32 = 1
  func change() { revision += 1 }
  func home() -> String { "/" }
  func resolve(_ path: String) -> String { path }
  func stat(_ path: String) -> FileStamp { .init(size: 9000, modified: revision, directory: false) }
  func list(_ path: String) -> [FileRow] { [] }
  func read(_ path: String, limit: Int) throws -> Data { throw CocoaError(.fileReadUnknown) }
  func bytes(_ path: String, range: Range<UInt64>, interactive: Bool) throws -> Data {
    #expect(!interactive)
    ranges.append(range)
    return Data("# Read \(revision)\n\nThe **first** line\nand [link](relative).\n\nLater.".utf8)
  }
}

@Test func previewsAreBoundedStampedAndDeferredByDataSaver() async throws {
  let files = PreviewFiles()
  let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = DocumentCache(directory: directory)
  let key = CacheIdentity(profile: UUID(), account: "test", fingerprint: "test", path: "/note.md")
  let stamp = await files.stat(key.path)
  #expect(try await cache.preview(key, stamp: stamp, files: files, saver: true) == nil)
  #expect(await files.ranges.isEmpty)
  let preview = try await cache.preview(key, stamp: stamp, files: files, saver: false)
  #expect(preview?.title == "Read 1" && preview?.excerpt == "The first line and link.")
  let reopened = DocumentCache(directory: directory)
  #expect(try await reopened.preview(key, stamp: stamp, files: files, saver: false) == preview)
  #expect(try await reopened.preview(key, stamp: stamp, files: files, saver: true) == nil)
  await files.change()
  let changed = try await reopened.preview(
    key, stamp: await files.stat(key.path), files: files, saver: false)
  #expect(changed?.title == "Read 2")
  #expect(await files.ranges == [0..<4096, 0..<4096])
  let metadata = DocumentPreview("---\ntitle: 'Front matter'\n---\n\nFirst paragraph.")
  #expect(metadata.title == "Front matter" && metadata.excerpt == "First paragraph.")
}

@Test func websitePicturesFollowHostIdentityAndMembership() async throws {
  let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = DocumentCache(directory: directory)
  let key = CacheIdentity(profile: UUID(), account: "reader", fingerprint: "first", path: ":6006")
  let changed = CacheIdentity(
    profile: key.profile, account: key.account, fingerprint: "second", path: key.path)
  try await cache.keepWebsitePictures([key])
  try await cache.saveWebsitePicture(Data([1]), key: key)
  #expect(try await cache.websitePicture(key) == Data([1]))
  try await cache.keepWebsitePictures([changed])
  try await cache.saveWebsitePicture(Data([2]), key: key)
  #expect(try await cache.websitePicture(changed) == nil)
  try await cache.keepWebsitePictures([key])
  #expect(try await cache.websitePicture(key) == nil)
}

@Test func outlineTracksAllFortyHeadingsIncludingNestedSections() throws {
  let context = try #require(JSContext())
  let script = """
    (function(offset) {
      const document = {querySelectorAll(selector) {
        return Array.from({length: 40}, (_, i) => ({
          tagName: 'H' + (i % 6 + 1),
          getBoundingClientRect: () => ({top: i * 120 - offset})
        })).filter(n => selector.includes(n.tagName.toLowerCase()));
      }};
      \(HeadingTracking.script)
      return index;
    })
    """
  let section = try #require(context.evaluateScript(script))
  for i in 0..<40 {
    #expect(section.call(withArguments: [i * 120 + 50])?.toInt32() == Int32(i))
  }
}

@Test @MainActor func browsingFixtures() throws {
  for sample in BrowsingFixture.allCases { #expect(sample.observed == sample.expected) }
  for sample in PNGFixture.allCases { #expect(try PNGTextReader.read(data: sample.data())["prompt"] == sample.prompt) }
  for sample in connectionFixtures {
    #expect(sample.cause.wording.title == sample.title)
    let message: String
    switch sample.cause {
    case .hostKeyChanged: message = TransportError.hostKeyChanged(.init(type: "test", fingerprint: "changed")).message(for: "example.invalid")
    case .hostKeyNotTrusted: message = TransportError.hostKeyRefused.message(for: "example.invalid")
    case .signInRefused: message = TransportError.signInRefused([]).message(for: "example.invalid")
    case .connectionRefused: message = TransportError.connectionRefused.message(for: "example.invalid")
    case .connectionLost: message = TransportError.disconnected.message(for: "example.invalid")
    case .hostNotFound: message = ServiceBrowser.failureMessage(URLError(.cannotFindHost))
    case .timedOut: message = ServiceBrowser.failureMessage(URLError(.timedOut))
    }
    #expect(message == sample.cause.message)
  }
}

@Test @MainActor func savedNameOrderAndNewProfileDefault() async throws {
  let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "preferences.json")
  let host = UUID()
  // Version 1 encoded the UUID-keyed dictionary as alternating keys and values.
  let legacy = """
    {"version":1,"preferences":{"hosts":[],"history":[],"plugins":{},
      "folderOrder":["\(host.uuidString)","Name"]}}
    """
  try Data(legacy.utf8).write(to: url)
  let core = try MobileComposition(directory: directory, cache: directory.appending(path: "cache"), keys: DemoKeys())
  await core.runtime.settled()
  let preferences = try #require(core.runtime.service(Profiles.self))
  let rows = [
    FileRow(name: "A.txt", stamp: .init(modified: 3, directory: false)),
    FileRow(name: "Archive", stamp: .init(modified: 1, directory: true)),
    FileRow(name: "Z.txt", stamp: .init(modified: 4, directory: false)),
    FileRow(name: "Work", stamp: .init(modified: 2, directory: true)),
  ]
  func names(for host: UUID) -> [String] {
    var profile = Profile(host: "example.invalid", account: "")
    profile.id = host
    let workspace = HostWorkspace(core: core, profile: profile, profiles: preferences, initialRoute: nil,
      choose: { _ in }, resume: { _, _ in }, add: { _ in }, settings: {}, hosts: {})
    let screen = FolderScreen(workspace: workspace, path: "/", homePath: "/", files: workspace.files,
      reader: nil, limit: 0, history: [], actions: nil, open: { _ in }, rows: rows)
    return (screen.group(true) + screen.group(false)).map(\.name)
  }
  #expect(names(for: host) == ["Archive", "Work", "A.txt", "Z.txt"])
  #expect(names(for: UUID()) == ["Work", "Archive", "Z.txt", "A.txt"])
  await core.runtime.shutdown()
}

@Test func imageCaptionUsesHostOrderAmongVisibleImages() {
  func row(_ name: String, _ modified: UInt32) -> FileRow {
    FileRow(name: name, stamp: .init(modified: modified, directory: false))
  }
  let rows = [row("a.jpg", 1), row("b.jpg", 2), row(".old.jpg", 3), row("note.md", 4)]
  #expect(imagePosition("/album/a.jpg", rows: rows, order: .name) == "1 of 2")
  #expect(imagePosition("/album/a.jpg", rows: rows, order: .modified) == "2 of 2")
}
