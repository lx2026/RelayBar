import BridgeProtocol
import Combine
import Composition
import Foundation

/// Folder metadata only. Expanding a row never downloads media or walks descendants.
@MainActor public final class RemoteFolderIndex: ObservableObject {
  public typealias Loader = @Sendable (BridgeSource, String) async throws -> ScanResult
  public struct Node: Sendable {
    public let path: String
    public var children: [String] = []
    public var isLoaded = false
    public var count = 0
    public var error: String?
  }
  public struct Row: Identifiable {
    public var id: String { node.path }
    public let node: Node
    public let depth: Int
  }
  public nonisolated static let maximumFolders = 512
  public nonisolated static let maximumAssets = 20_000
  public nonisolated static let maximumNodes = 20_000
  public nonisolated static let maximumDepth = 64
  public let source: BridgeSource
  @Published public private(set) var rootPath: String
  @Published public private(set) var nodes: [String: Node] = [:]
  @Published public private(set) var expanded: Set<String> = []
  @Published public private(set) var loading: Set<String> = []
  public private(set) var revision = 0
  private let loader: Loader
  private struct Cached { let result: ScanResult; let date: Date; var used: Date }
  private struct Flight { let id: UUID; let task: Task<ScanResult, Error>; var consumers: Set<UUID> }
  private var cache: [String: Cached] = [:]
  private var flights: [String: Flight] = [:]
  private let work = EffectScope()
  private let authorize: @MainActor () throws -> Void
  private var retirement: Task<Void, Never>?
  public private(set) var isStopped = false
  var didShutdown: (() -> Void)?

  public init(source: BridgeSource, path: String, authorize: @escaping @MainActor () throws -> Void = {}, loader: @escaping Loader) {
    self.source = source; rootPath = Self.normalize(path); self.loader = loader
    self.authorize = authorize
    nodes[rootPath] = Node(path: rootPath)
    expanded = [rootPath]
  }
  deinit { for flight in flights.values { flight.task.cancel() } }

  public static func normalize(_ path: String) -> String { "/" + path.split(separator: "/").joined(separator: "/") }
  public static func contains(_ path: String, in root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
  }
  public var rows: [Row] {
    var result: [Row] = [], stack: [(String, Int)] = [(rootPath, 0)]
    while let (path, depth) = stack.popLast() {
      guard let node = nodes[path] else { continue }
      result.append(Row(node: node, depth: depth))
      if expanded.contains(path) {
        stack.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
      }
    }
    return result
  }
  public func setExpanded(_ path: String, _ value: Bool) {
    if value { expanded.insert(path) } else { expanded.remove(path) }
  }
  public func files(at path: String) -> [PhotoItem] { cachedFiles(at: path) ?? [] }
  /// The files of the listing cached for `path`: empty for an empty folder, nil when no listing is cached.
  public func cachedFiles(at path: String) -> [PhotoItem]? { cache[path]?.result.files }
  /// Moving up extends the existing tree rather than discarding its hierarchy.
  public func reveal(_ path: String) {
    let path = Self.normalize(path)
    if Self.contains(rootPath, in: path), path != rootPath {
      var child = rootPath
      while child != path {
        let parent = (child as NSString).deletingLastPathComponent
        if nodes[parent] == nil { nodes[parent] = Node(path: parent, children: [child]) }
        else if nodes[parent]?.children.contains(child) == false { nodes[parent]?.children.append(child) }
        expanded.insert(parent); child = parent
      }
      rootPath = path
    }
    var ancestor = (path as NSString).deletingLastPathComponent
    while Self.contains(ancestor, in: rootPath) {
      expanded.insert(ancestor)
      if ancestor == rootPath || ancestor == "/" { break }
      ancestor = (ancestor as NSString).deletingLastPathComponent
    }
  }
  public func invalidate(_ path: String) {
    revision += 1
    for key in cache.keys where Self.contains(key, in: path) { cache.removeValue(forKey: key) }
    for key in Array(flights.keys) where Self.contains(key, in: path) {
      flights.removeValue(forKey: key)?.task.cancel(); loading.remove(key)
    }
  }
  public func remove(_ items: [PhotoItem]) {
    let paths = Set(items.flatMap { $0.fileMembers.map(\.relativePath) })
    revision += 1
    let folders = Set(items.map(\.folderRelativePath))
    for path in Array(flights.keys) where folders.contains(path) {
      flights.removeValue(forKey: path)?.task.cancel(); loading.remove(path)
    }
    for path in cache.keys {
      guard let old = cache[path] else { continue }
      let photos = old.result.photos.filter { !paths.contains($0.relativePath) }
      let files = old.result.files.filter { !paths.contains($0.relativePath) }
      cache[path] = Cached(result: ScanResult(photos: photos, rootFolder: old.result.rootFolder, files: files), date: old.date, used: old.used)
    }
    objectWillChange.send()
  }
  public func cancelAll() {
    for flight in flights.values { flight.task.cancel() }
    flights.removeAll(); loading.removeAll()
  }
  public func stop() {
    guard !isStopped else { return }
    isStopped = true
    let pending = Array(flights.values)
    cancelAll(); work.invalidate()
    retirement = Task { [self] in
      await work.dispose()
      for flight in pending { _ = try? await flight.task.value }
      didShutdown?(); didShutdown = nil
    }
  }
  public func shutdown() async { stop(); await retirement?.value }

  public func load(_ path: String) async throws -> ScanResult {
    try Task.checkCancellation()
    guard !isStopped else { throw CancellationError() }
    try authorize()
    guard FrameBridgeEnvironment.validPath(path), Self.contains(path, in: rootPath) else {
      throw BridgeError("Choose a folder within this tree.")
    }
    if let cached = cache[path], cached.date.timeIntervalSinceNow > -60 {
      cache[path]?.used = .now
      return cached.result
    }
    let consumer = UUID(), flight: Flight
    if let current = flights[path] {
      flight = current; flights[path]?.consumers.insert(consumer)
    } else {
      let loader = loader, source = source
      let task = Task { [work] in try await work.run { try await loader(source, path) } }
      flight = Flight(id: UUID(), task: task, consumers: [consumer])
      flights[path] = flight; loading.insert(path)
      nodes[path]?.error = nil
    }
    return try await withTaskCancellationHandler {
      do {
        let result = try await flight.task.value
        try Task.checkCancellation()
        guard !isStopped, flights[path]?.id == flight.id else { throw CancellationError() }
        try authorize()
        // A cancelled/old request must never overwrite a replacement load.
        try install(result, path: path)
        release(path, id: flight.id, consumer: consumer)
        return result
      } catch {
        if !(error is CancellationError), flights[path]?.id == flight.id {
          revision += 1
          nodes[path]?.error = error.localizedDescription
        }
        release(path, id: flight.id, consumer: consumer)
        throw error
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.release(path, id: flight.id, consumer: consumer) }
    }
  }
  private func release(_ path: String, id: UUID, consumer: UUID) {
    guard flights[path]?.id == id else { return }
    flights[path]?.consumers.remove(consumer)
    if flights[path]?.consumers.isEmpty == true {
      flights.removeValue(forKey: path)?.task.cancel(); loading.remove(path)
    }
  }
  private func install(_ result: ScanResult, path: String) throws {
    revision += 1
    let children = result.rootFolder.children.map(\.relativePath)
    let added = children.filter { nodes[$0] == nil }.count
    guard nodes.count + added <= Self.maximumNodes else {
      throw BridgeError("Folder tree limit reached. Open a smaller folder.")
    }
    nodes[path] = Node(path: path, children: children, isLoaded: true, count: result.photos.count)
    for child in children where nodes[child] == nil { nodes[child] = Node(path: child) }
    cache[path] = Cached(result: result, date: .now, used: .now)
    var assets = cache.values.reduce(0) { $0 + $1.result.files.count }
    for key in cache.keys.sorted(by: { cache[$0]!.used < cache[$1]!.used })
      where key != path && (cache.count > 64 || assets > Self.maximumAssets) {
      if let removed = cache.removeValue(forKey: key) { assets -= removed.result.files.count }
    }
  }
}
