import Composition
import CryptoKit
import Foundation
import RelayTransport

package let fileSearchPlugin = PluginDescriptor(
  id: "file-search", title: "File Search", summary: "Find files and folders by name in Places.",
  symbol: "doc.text.magnifyingglass", isOnByDefault: true, realmRelativeFeatures: ["search.files"])

package enum FileSearch: ServiceKey { package typealias Value = NameIndex }

package struct NameHit: Identifiable, Sendable {
  package let place: Place
  package let subtitle: String
  package var id: String { place.path }
}

struct IndexedName: Codable, Sendable {
  let name: String
  let directory: Bool
}

private func folded(_ value: String) -> String {
  value.folding(
    options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}

enum NameMatcher {
  struct Candidate {
    let path: String
    let relative: String
    let rootLabel: String?
    let entry: IndexedName
  }

  static func matches(_ query: String, candidates: [Candidate], titles: [String: String])
    -> [NameHit]
  {
    let text = folded(query).trimmingCharacters(in: .whitespacesAndNewlines)
    let words = text.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return [] }
    typealias Rank = (Int, Int, Int, String)
    var best: [String: (rank: Rank, hit: NameHit)] = [:]
    for item in candidates {
      if Task.isCancelled { return [] }
      let title = titles[item.path]
      let names = [item.entry.name, title].compactMap { $0 }.map(folded)
      let path = folded(item.relative)
      guard
        words.allSatisfy({ word in
          path.contains(word) || names.contains(where: { $0.contains(word) })
        })
      else { continue }
      let tier: Int
      if names.contains(where: { $0.hasPrefix(text) }) {
        tier = 0
      } else if names.contains(where: { name in
        var startOfWord = true
        for index in name.indices {
          if startOfWord && name[index...].hasPrefix(text) { return true }
          startOfWord = !name[index].isLetter && !name[index].isNumber
        }
        return false
      }) {
        tier = 1
      } else if names.contains(where: { $0.contains(text) }) {
        tier = 2
      } else {
        tier = 3
      }
      let rank: Rank = (tier, title == nil ? 1 : 0, item.relative.count, item.path)
      if let previous = best[item.path], previous.rank <= rank { continue }
      let parent = (item.relative as NSString).deletingLastPathComponent
      let subtitle = [
        item.rootLabel, parent.isEmpty ? (item.rootLabel == nil ? "." : nil) : parent,
      ]
      .compactMap { $0 }.joined(separator: " · ")
      best[item.path] = (
        rank,
        NameHit(place: .init(path: item.path, directory: item.entry.directory), subtitle: subtitle)
      )
    }
    return best.values.sorted { $0.rank < $1.rank }.prefix(30).map(\.hit)
  }
}

package actor NameIndex {
  private struct Tree: Codable {
    var folders: [String: [IndexedName]] = [:]
    var pending: [String]
    var files = 0
    var directories = 0
    var limited = false
    var refreshing = false
    var finished: Date?
  }

  package static let limitNotice = "Limit reached. Pin a deeper folder to search it."
  package static func progress(_ count: Int) -> String { "Indexing · \(count) items" }
  private static let skips: Set<String> = [
    "node_modules", "__pycache__", "venv", "env", "site-packages", "build", "dist", "target",
    "DerivedData", "Pods",
  ]
  private let files: any RemoteFiles
  private let home: String
  private let roots: [String]
  private let directory: URL
  private let identity: String
  private let fileLimit: Int
  private let folderLimit: Int
  private var trees: [String: Tree] = [:]
  private var checkedRoots = Set<String>()
  private var walking: Task<Void, Never>?
  private var requested = false
  private var stopped = false
  private var traffic = 0
  private var revision = 0
  private var dirty: Set<String> = []
  private var checkpoint = ContinuousClock.now

  init(
    files: any RemoteFiles, directory: URL, profile: Profile, fingerprint: String, home: String,
    pins: [String], fileLimit: Int = 20_000, folderLimit: Int = 3_000
  ) {
    self.files = files
    self.directory = directory.appending(path: profile.id.uuidString)
    identity = Self.hash(profile.account + "\u{0}" + fingerprint)
    self.home = home
    roots = [home] + pins.filter { $0 != home }
    self.fileLimit = fileLimit
    self.folderLimit = folderLimit
  }

  private static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // Place directories let an offline unpin remove every account/key version of that place.
  static func prune(directory: URL, choices: Preferences) {
    let fm = FileManager.default
    func children(_ url: URL) -> [URL] {
      (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }
    for host in children(directory) {
      guard let id = UUID(uuidString: host.lastPathComponent),
        choices.hosts.contains(where: { $0.id == id }),
        choices.enabled(fileSearchPlugin, host: id)
      else {
        try? fm.removeItem(at: host)
        continue
      }
      let keep = Set(
        (choices.places(for: id).filter { $0.directory != false }.map(\.path)
          + [choices.homeFolders?[id]].compactMap { $0 }).map(hash))
      for place in children(host) where !keep.contains(place.lastPathComponent) {
        try? fm.removeItem(at: place)
      }
    }
  }

  private func url(_ root: String) -> URL {
    directory.appending(path: Self.hash(root)).appending(path: identity)
  }

  func prepare(deferred: Bool) {
    guard !stopped else { return }
    for root in roots {
      let url = url(root)
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var tree =
        (try? JSONDecoder().decode(Tree.self, from: Data(contentsOf: url))) ?? Tree(pending: [root])
      if let date = tree.finished, Date().timeIntervalSince(date) >= 900 {
        tree.pending = [root]
        tree.refreshing = true
        tree.finished = nil
        tree.limited = false
      }
      trees[root] = tree
    }
    if !deferred { start() }
  }

  private func start() {
    requested = true
    guard !stopped, walking == nil, roots.contains(where: { trees[$0]?.pending.isEmpty == false })
    else { return }
    walking = Task(priority: .background) { await walk() }
  }

  func stop() async {
    stopped = true
    walking?.cancel()
    await walking?.value
    save()
  }

  private func save() {
    for root in dirty {
      if let tree = trees[root] {
        try? JSONEncoder().encode(tree).write(to: url(root), options: .atomic)
      }
    }
    dirty.removeAll()
    checkpoint = .now
  }

  func foreground<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
    traffic += 1
    defer { traffic -= 1 }
    return try await operation()
  }

  // The SFTP listing visitor calls this before consuming the next entry or requesting another page.
  @TaskLocal static var walker: NameIndex?
  func yieldToPages() async throws {
    while traffic > 0 { try await Task.sleep(for: .milliseconds(15)) }
    try Task.checkCancellation()
  }

  private var lastFailure: String?
  /// What the walk is waiting on, for a test or log line when indexing does not finish.
  package var diagnostics: String {
    let pending = trees.values.reduce(0) { $0 + $1.pending.count }
    return "stopped=\(stopped) walking=\(walking != nil) traffic=\(traffic) pending=\(pending)"
      + " lastFailure=\(lastFailure ?? "none")"
  }
  private func canList(_ root: String) async throws -> Bool {
    if root == home || checkedRoots.contains(root) { return true }
    // A pinned folder can itself be a link, even when its parent is outside every place.
    guard try await files.resolve(root) == root else {
      trees[root] = Tree(pending: [])
      finishFolder(root)
      return false
    }
    checkedRoots.insert(root)
    return true
  }

  private func walk() async {
    defer {
      save()
      walking = nil
      revision += 1
    }
    let files = files
    while !Task.isCancelled {
      // Four folders at a time, shallowest first. One at a time made a large place take minutes,
      // because each small folder costs several round trips.
      var batch: [(root: String, folder: String)] = []
      do { try await yieldToPages() } catch { return }
      for root in roots where batch.count < 4 && trees[root]?.pending.isEmpty == false {
        do {
          guard try await canList(root) else { continue }
        } catch {
          lastFailure = "\(type(of: error))"
          if Task.isCancelled || error is TransportError || error as? SFTPError == .closed {
            return
          }
          // A place that cannot be resolved is left out; the others are still walked.
          trees[root]?.pending.removeAll()
          finishFolder(root)
          continue
        }
        for folder in trees[root]?.pending.prefix(4 - batch.count) ?? [] {
          batch.append((root, folder))
        }
      }
      if batch.isEmpty { return }
      let listings = await withTaskGroup(of: (Int, Result<FolderListing, any Error>).self) {
        group in
        for (index, item) in batch.enumerated() {
          group.addTask {
            do {
              let listing = try await Self.$walker.withValue(self) {
                try await files.listing(item.folder)
              }
              return (index, .success(listing))
            } catch { return (index, .failure(error)) }
          }
        }
        var done: [(Int, Result<FolderListing, any Error>)] = []
        for await result in group { done.append(result) }
        return done.sorted { $0.0 < $1.0 }
      }
      // A listing that returned is whole, so it is kept even when its neighbours were interrupted.
      var interrupted = Task.isCancelled
      for (index, result) in listings {
        let (root, folder) = batch[index]
        switch result {
        case .success(let listing):
          // A foreground listing may have replaced this folder while the request was in flight.
          if trees[root]?.pending.contains(folder) == true {
            apply(listing, folder: folder, root: root)
          }
        case .failure(let error):
          lastFailure = "\(type(of: error))"
          if error is CancellationError || error is TransportError
            || error as? SFTPError == .closed
          {
            interrupted = true
            continue
          }
          // Leave inaccessible folders out; other branches can still be searched.
          trees[root]?.pending.removeAll { $0 == folder }
          finishFolder(root)
        }
      }
      if interrupted { return }
      await Task.yield()
    }
  }

  func observed(_ listing: FolderListing, folder: String) async {
    guard !stopped else { return }
    for root in roots {
      let prefix = root == "/" ? "/" : root + "/"
      guard folder == root || folder.hasPrefix(prefix) else { continue }
      let components = folder == root ? [] : folder.dropFirst(prefix.count).split(separator: "/")
      guard components.count < (root == home ? 2 : 12),
        components.allSatisfy({ !$0.hasPrefix(".") && !Self.skips.contains(String($0)) })
      else { continue }
      guard (try? await canList(root)) == true, !stopped else { continue }
      // A directly opened folder may precede the walk. Resolve it before adopting its
      // ancestors so navigation through a symlink cannot extend the walk outside a place.
      if folder != root && trees[root]?.folders[folder] == nil
        && trees[root]?.pending.contains(folder) != true
      {
        guard (try? await files.resolve(folder)) == folder, !stopped,
          var tree = trees.removeValue(forKey: root)
        else { continue }
        var parent = root
        for component in components {
          let name = String(component)
          if tree.folders[parent]?.contains(where: { $0.directory && $0.name == name }) != true {
            guard tree.directories < folderLimit else {
              tree.limited = true
              break
            }
            tree.folders[parent, default: []].append(.init(name: name, directory: true))
            tree.directories += 1
          }
          parent = (parent as NSString).appendingPathComponent(name)
          if tree.folders[parent] == nil && !tree.pending.contains(parent) {
            tree.pending.append(parent)
          }
        }
        trees[root] = tree
        guard parent == folder else {
          finishFolder(root)
          continue
        }
      }
      apply(listing, folder: folder, root: root)
    }
    if requested { start() }
  }

  private func apply(_ listing: FolderListing, folder: String, root: String) {
    guard var tree = trees.removeValue(forKey: root) else { return }
    let old = tree.folders.removeValue(forKey: folder) ?? []
    tree.files -= old.filter { !$0.directory }.count
    tree.directories -= old.filter(\.directory).count
    tree.pending.removeAll { $0 == folder }
    let depth = folder.split(separator: "/").count - root.split(separator: "/").count + 1
    var entries: [IndexedName] = []
    tree.limited = tree.limited || listing.truncated
    for row in listing.rows where !row.name.hasPrefix(".") {
      if row.stamp.directory {
        guard !row.symbolicLink, !Self.skips.contains(row.name) else { continue }
        guard tree.directories < folderLimit else {
          tree.limited = true
          continue
        }
        tree.directories += 1
      } else {
        guard tree.files < fileLimit else {
          tree.limited = true
          continue
        }
        tree.files += 1
      }
      entries.append(.init(name: row.name, directory: row.stamp.directory))
    }
    let children = Set(entries.filter(\.directory).map(\.name))
    for removed in old where removed.directory && !children.contains(removed.name) {
      let path = (folder as NSString).appendingPathComponent(removed.name)
      tree.pending.removeAll { $0 == path || $0.hasPrefix(path + "/") }
      for key in Array(tree.folders.keys) where key == path || key.hasPrefix(path + "/") {
        for entry in tree.folders.removeValue(forKey: key) ?? [] {
          if entry.directory { tree.directories -= 1 } else { tree.files -= 1 }
        }
      }
    }
    let known = Set(old.filter(\.directory).map(\.name))
    for entry in entries where entry.directory {
      let child = (folder as NSString).appendingPathComponent(entry.name)
      if depth < (root == home ? 2 : 12) {
        if tree.refreshing || (!known.contains(entry.name) && tree.folders[child] == nil) {
          tree.pending.append(child)
        }
      } else {
        tree.limited = true
      }
    }
    if tree.refreshing {  // A page can refresh a folder already in the queue.
      var seen = Set<String>()
      tree.pending = tree.pending.filter { seen.insert($0).inserted }
    }
    tree.folders[folder] = entries
    trees[root] = tree
    finishFolder(root)
  }

  private func finishFolder(_ root: String) {
    if trees[root]?.pending.isEmpty == true {
      trees[root]?.refreshing = false
      if trees[root]?.finished == nil { trees[root]?.finished = Date() }
    } else {
      trees[root]?.finished = nil
    }
    dirty.insert(root)
    revision += 1
    if checkpoint.duration(to: .now) >= .seconds(2) { save() }
  }

  package func results(_ query: String, visits: [Visit], since previous: Int?) async -> (
    Int, [NameHit], String?
  )? {
    start()
    guard revision != previous else { return nil }
    let count = trees.values.reduce(0) { $0 + $1.files + $1.directories }
    let status =
      walking != nil
      ? Self.progress(count)
      : trees.values.contains(where: \.limited)
        ? Self.limitNotice : nil
    let current = revision
    let hits = await Self.match(query, visits: visits, trees: trees, roots: roots, home: home)
    return (current, hits, status)
  }

  @concurrent private static func match(
    _ query: String, visits: [Visit], trees: [String: Tree],
    roots: [String], home: String
  ) async -> [NameHit] {
    var candidates: [NameMatcher.Candidate] = []
    for root in roots {
      let label =
        roots.count == 1 ? nil : (root == home ? "Home" : (root as NSString).lastPathComponent)
      for (folder, entries) in trees[root]?.folders ?? [:] {
        if Task.isCancelled { return [] }
        for entry in entries {
          let path = (folder as NSString).appendingPathComponent(entry.name)
          candidates.append(
            .init(
              path: path, relative: String(path.dropFirst(root == "/" ? 1 : root.count + 1)),
              rootLabel: label, entry: entry))
        }
      }
    }
    return NameMatcher.matches(
      query, candidates: candidates,
      titles: Dictionary(
        visits.map { ($0.path, $0.title) }, uniquingKeysWith: { first, _ in first }))
  }
}

enum SessionFiles: ServiceKey { typealias Value = any RemoteFiles }

struct PlainFilesFeature: Feature {
  @Need(SessionFiles.self) var source
  @Offer(Files.self) var files
  func run(_ context: FeatureContext) async throws { files.set(source) }
}

struct SearchFilesFeature: Feature {
  let profile: Profile
  let directory: URL
  let home: String?
  let places: [String]
  let deferred: Bool
  @Need(SessionFiles.self) var source
  @Need(Trust.self) var pins
  @Offer(FileSearch.self) var search
  @Offer(Files.self) var files
  func run(_ context: FeatureContext) async throws {
    // File browsing is available even before a pin or home directory is known.
    guard let fingerprint = pins.value[profile.id.uuidString]?.fingerprint else {
      files.set(source)
      return
    }
    let base: String
    if let home {
      base = home
    } else {
      guard let resolved = try? await source.home() else {
        files.set(source)
        return
      }
      base = resolved
    }
    let index = NameIndex(
      files: source, directory: directory, profile: profile,
      fingerprint: fingerprint, home: base, pins: places)
    try context.checkActive()
    try context.effect("File name index") { await index.stop() }
    await index.prepare(deferred: deferred)
    try context.checkActive()
    search.set(index)
    func observing(_ base: some RemoteFiles) -> any RemoteFiles {
      IndexedFiles(base: base, index: index)
    }
    files.set(observing(source))
  }
}

struct IndexedFiles<Base: RemoteFiles>: RemoteFiles {
  let base: Base
  let index: NameIndex
  func home() async throws -> String { try await base.home() }
  func resolve(_ path: String) async throws -> String { try await base.resolve(path) }
  func stat(_ path: String) async throws -> FileStamp {
    try await index.foreground { try await base.stat(path) }
  }
  func listing(_ path: String) async throws -> FolderListing {
    let result = try await index.foreground { try await base.listing(path) }
    await index.observed(result, folder: path)
    return result
  }
  func list(_ path: String) async throws -> [FileRow] { try await listing(path).rows }
  func read(_ path: String, limit: Int) async throws -> Data {
    try await index.foreground { try await base.read(path, limit: limit) }
  }
}

extension IndexedFiles: RangeFiles where Base: RangeFiles {
  func bytes(_ path: String, range: Range<UInt64>, interactive: Bool) async throws -> Data {
    try await index.foreground {
      try await base.bytes(path, range: range, interactive: interactive)
    }
  }
}
