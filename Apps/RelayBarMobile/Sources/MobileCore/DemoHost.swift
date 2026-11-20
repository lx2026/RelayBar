import Composition
import CryptoKit
import Foundation

package struct DemoKeys: KeyProvider {
  private let value = P256.Signing.PrivateKey()
  package init() {}
  package func existingKey() async throws -> DeviceKey? { .memory(value) }
  package func key() async throws -> DeviceKey { .memory(value) }
}
private final class DemoRemovals: @unchecked Sendable {
  private let lock = NSLock()
  private var paths: Set<String> = []
  func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
  func remove(_ path: String) throws {
    try lock.withLock {
      guard paths.insert(path).inserted else { throw CocoaError(.fileNoSuchFile) }
    }
  }
}

package struct DemoHost: RangeFiles, HostConnection {
  package static let certificateFingerprint = SHA256.hash(
    data: Data("Demo service certificate".utf8)
  ).map { String(format: "%02X", $0) }.joined(separator: ":")
  package static let folder = "/runs/poster-study"
  package static let sessions = folder + "/notes/sessions"
  package static let article = sessions + "/retrieval-ablation-3.md"
  package static let report = folder + "/report.md"
  package static let image = folder + "/samples/grid-0031.png"
  package static let identity = Identity(
    algorithm: "ssh-ed25519", fingerprint: "SHA256:8hV2nQ0rT1mXc4LkZp7YbWdE9sFaGuJo3iN6tR5yKwA")
  private let removed = DemoRemovals()
  private let started = Date()
  private let contents: [String: Data]
  private let modified = UInt32(Date().addingTimeInterval(-720).timeIntervalSince1970)
  private let folders: Set<String>
  let notebookPort: UInt16
  package init(notebookPort: UInt16 = 8888) throws {
    self.notebookPort = notebookPort
    guard let base = Bundle.module.url(forResource: "Workspace", withExtension: nil),
      let entries = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: [.isDirectoryKey])
    else { throw CocoaError(.fileNoSuchFile) }
    var files: [String: Data] = [:]
    var dirs: Set<String> = ["/", "/runs", Self.folder]
    for case let url as URL in entries {
      let path =
        Self.folder + "/"
        + url.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")
      if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        dirs.insert(path)
      } else {
        files[path] = try Data(contentsOf: url)
      }
    }
    files[Self.folder + "/samples/grid-0030.png"] = files[Self.folder + "/grid-0030.png"]
    files[Self.folder + "/samples/grid-0032.png"] = files[Self.folder + "/grid-0029.png"]
    files[Self.folder + "/training.log"] = Data("Training started\n".utf8)
    dirs.formUnion([
      Self.sessions, Self.sessions + "/figures", Self.sessions + "/transcripts",
      Self.folder + "/notes/monthly",
    ])
    files[Self.folder + "/samples/.catalog"] = Data("catalog".utf8)
    let notes = [
      (
        "check-in", "Thursday check-in",
        "Seed sweep finished overnight. Two runs diverged after step 9k, both on the long-headline briefs. Captioner retries are steady."
      ),
      (
        "templates-b-c", "Prompt templates B and C, side by side",
        "Template B asks for the grid before the style, and keeps headlines inside the safe area far more often."
      ),
      (
        "eval-protocol-v2", "Evaluation protocol v2",
        "Pairwise preference, three raters, ties allowed. Raters see the brief but never the condition name."
      ),
      (
        "monday-planning", "Monday planning",
        "Review the briefs with long headlines before selecting the next round of layouts."
      ),
      (
        "monitoring-checklist", "Monitoring checklist",
        "Check the held-out split before comparing run metrics. Record the run identifier beside each chart."
      ),
      (
        "monthly-report", "Monthly report, October",
        "Most of the gains came from matching the layout to the length of the headline."
      ),
    ]
    for (name, title, body) in notes {
      files[Self.sessions + "/" + name + ".md"] = Data(("# " + title + "\n\n" + body).utf8)
    }
    for day in 1...18 {
      files[Self.folder + "/notes/sessions/Session " + String(day) + ".md"] = Data(
        "# Session notes".utf8)
    }
    contents = files
    folders = dirs
  }
  private func payload(_ path: String) throws -> Data {
    if path == Self.folder + "/training.log" {
      let epoch = max(12, Int(Date().timeIntervalSince(started)) + 12)
      let lines = (max(0, epoch - 256)...epoch).map {
        "Epoch " + String($0) + "   validation complete"
      }
      return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
    guard let bytes = contents[path] else { throw CocoaError(.fileNoSuchFile) }
    return bytes
  }
  package func files() async throws -> any RemoteFiles { self }
  package func run(_ publish: @escaping @MainActor @Sendable (ConnectionEvent) -> Void) async {
    await publish(.ready)
  }
  package func suspend() async {}
  package func home() -> String { "/" }
  package func resolve(_ path: String) throws -> String {
    if path == "." { return "/" }
    guard !removed.contains(path), contents[path] != nil || folders.contains(path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return path
  }
  package func stat(_ path: String) throws -> FileStamp {
    let path = try resolve(path)
    let age: UInt32
    switch (path as NSString).lastPathComponent {
    case "notes.txt": age = 24 * 3600
    case "metrics.json", "grid-0029.png", "grid-0030.png": age = 3 * 3600
    case "check-in.md": age = 3600
    case "templates-b-c.md", "eval-protocol-v2.md": age = 86400
    default: age = path.contains("/sessions/") && path != Self.article ? 9 * 86400 : 720
    }
    return FileStamp(
      size: folders.contains(path) ? nil : UInt64(try payload(path).count),
      modified: path.hasSuffix("/training.log")
        ? UInt32(Date().timeIntervalSince1970) : modified + 720 - age,
      directory: folders.contains(path))
  }
  package func list(_ path: String) throws -> [FileRow] {
    let parent = try resolve(path)
    return try (Array(contents.keys) + Array(folders)).sorted().filter {
      !removed.contains($0) && $0 != parent && ($0 as NSString).deletingLastPathComponent == parent
    }.map { child in
      var row = FileRow(name: (child as NSString).lastPathComponent, stamp: try stat(child))
      if !row.stamp.directory {
        let stamp = row.stamp
        row.remove = {
          guard try stat(child) == stamp else { throw CompositionError("The file changed.") }
          try removed.remove(child)
        }
      }
      return row
    }
  }
  package func read(_ path: String, limit: Int) throws -> Data {
    _ = try resolve(path)
    let bytes = try payload(path)
    guard bytes.count <= limit else { throw CocoaError(.fileReadTooLarge) }
    return bytes
  }

  package func bytes(_ path: String, range: Range<UInt64>, interactive: Bool) async throws -> Data {
    try Task.checkCancellation()
    _ = try resolve(path)
    let bytes = try payload(path)
    guard range.upperBound <= UInt64(bytes.count) else {
      throw CocoaError(.fileReadUnknown)
    }
    return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
  }

  @MainActor package func install(in core: MobileComposition) async throws -> Profile {
    await core.runtime.settled()
    guard let prefs = core.runtime.service(Profiles.self),
      let pins = core.runtime.service(Trust.self)
    else { throw CompositionError("Demo services unavailable.") }
    if let existing = prefs.value.hosts.first { return existing }
    let profile = Profile(host: "poster-studio", account: "reader")
    try pins.update { $0[profile.id.uuidString] = Self.identity }
    try prefs.update { value in
      value.hosts = [profile]
      value.homeFolders = [profile.id: home()]
      let study = Place(path: Self.folder, directory: true)
      value.togglePin(study, host: profile.id)
      let notes = Place(path: Self.folder + "/notes", directory: true)
      value.togglePin(notes, host: profile.id)
      value.select(study, host: profile.id)
      value.lastHost = profile.id
      value.pinnedServices = [
        profile.id: [ServiceAddress(port: 6006), ServiceAddress(port: notebookPort)]
      ]
      value.serviceTitles = [profile.id: [6006: "Run monitor", notebookPort: "Notebooks"]]
      for (path, title, heading) in [
        (Self.image, "grid-0031.png", ""),
        (Self.folder + "/notes/comparison.md", "Side-by-side comparison", ""),
        (Self.report, "Evaluation summary", "Results"),
      ] {
        var stamp = try stat(path)
        if path.hasSuffix("comparison.md") { stamp.modified = 1 }
        value.record(
          .init(
            profile: profile.id, path: path, title: title,
            excerpt:
              "Reviewers preferred template B in 31 of 48 comparisons, most clearly on posters with long headlines.",
            date: Date().addingTimeInterval(-720), stamp: stamp,
            position: .init(heading: heading.isEmpty ? nil : heading)))
      }
    }
    return profile
  }
}
