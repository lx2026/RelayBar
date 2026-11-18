import BridgeProtocol
import Foundation
import Darwin
import UniformTypeIdentifiers

public enum DocumentLocation: Hashable, Sendable {
  case local(URL)
  case remote(BridgeSource, String)
}

/// One root-scoped, read-only source for WebKit. It never accepts shell commands or mutation requests.
public actor DocumentResources {
  public static let documentLimit = 10 * 1_024 * 1_024
  public static let resourceLimit = 32 * 1_024 * 1_024
  public static let sessionLimit = 64 * 1_024 * 1_024
  public let location: DocumentLocation
  /// The custom-scheme host WebKit reaches this source by, and nothing else. Each source has its own, so a page
  /// loaded from one source can never be served from another.
  public nonisolated let host = UUID().uuidString.lowercased()
  private let client: (any RemoteAssetServing)?
  private struct Cached { let data: Data; let stamp: String }
  private var cache: [String: Cached] = [:]
  private var directories: [String: ScanResult] = [:]
  private var directoryTasks: [String: Task<ScanResult, Error>] = [:]
  private var loaded: Set<String> = []
  private var generation = UUID()
  public init(location: DocumentLocation, client: (any RemoteAssetServing)? = nil) { self.location = location; self.client = client }

  public func begin() async throws {
    // Revalidate cached bytes when returning to a document, including resources from earlier pages.
    loaded = Set(cache.keys)
    _ = try await refresh()
    loaded = []; generation = UUID()
    for task in directoryTasks.values { task.cancel() }; directoryTasks.removeAll()
    directories.removeAll()
  }

  public func clear() async {
    generation = UUID()
    let pending = Array(directoryTasks.values)
    for task in pending { task.cancel() }
    directoryTasks.removeAll(); directories.removeAll(); cache.removeAll(); loaded.removeAll()
    for task in pending { _ = try? await task.value }
  }
  public static func normalized(_ path: String) throws -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.isEmpty, parts.count <= 64, path.utf8.count <= 16_384,
          parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }),
          !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw BridgeError("Resource outside this folder.")
    }
    return parts.joined(separator: "/")
  }
  public func data(at path: String, limit: Int = DocumentResources.resourceLimit) async throws -> Data {
    let path = try Self.normalized(path), token = generation
    guard loaded.contains(path) || loaded.count < 128 else { throw BridgeError("This page requests too many files.") }
    loaded.insert(path)
    if let value = cache[path] {
      guard value.data.count <= limit else { throw BridgeError("File exceeds the preview limit.") }
      return value.data
    }
    let value: Cached
    switch location {
    case .local(let root):
      let (data, stamp) = try Self.readLocal(root: root, path: path, limit: limit)
      value = Cached(data: data, stamp: stamp)
    case .remote(let source, let root):
      guard let client else { throw BridgeError("Remote document access is unavailable.") }
      let absolute = (root == "/" ? "" : root) + "/" + path
      let parent = (absolute as NSString).deletingLastPathComponent
      let result: ScanResult
      if let current = directories[parent] { result = current }
      else {
        let task: Task<ScanResult, Error>
        if let pending = directoryTasks[parent] { task = pending }
        else {
          let client = client
          task = Task { try await client.list(source: source, path: parent) }
          directoryTasks[parent] = task
        }
        do { result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { if generation == token { directoryTasks.removeValue(forKey: parent) }; throw error }
        guard generation == token else { throw CancellationError() }
        directoryTasks.removeValue(forKey: parent)
        if directories.count >= 64 || directories.values.reduce(0, { $0 + $1.files.count }) + result.files.count > 20_000 { directories.removeAll() }
        directories[parent] = result
      }
      guard let item = result.files.first(where: { $0.relativePath == absolute }), item.fileSize <= limit else {
        throw BridgeError("File missing or exceeds the preview limit.")
      }
      let local = try await client.resolve(item, allowVideo: true)
      let data = try Data(contentsOf: local.url, options: .mappedIfSafe)
      guard data.count <= limit else { throw BridgeError("File exceeds the preview limit.") }
      value = Cached(data: data, stamp: item.remote?.entry.fingerprint ?? "")
    }
    try Task.checkCancellation()
    guard generation == token else { throw CancellationError() }
    // Evict bytes unrelated to this page before enforcing its aggregate budget.
    if cache.count >= 128 || cache.values.reduce(0, { $0 + $1.data.count }) + value.data.count > Self.sessionLimit {
      cache = cache.filter { loaded.contains($0.key) }
    }
    guard cache.values.reduce(0, { $0 + $1.data.count }) + value.data.count <= Self.sessionLimit else {
      throw BridgeError("Page resources exceed 64 MiB.")
    }
    cache[path] = value
    return value.data
  }
  /// One batch stat for remote resources, not one download per refresh.
  public func refresh() async throws -> Bool {
    let paths = loaded.sorted(), token = generation
    guard !paths.isEmpty else { return false }
    var stamps: [String: String] = [:]
    switch location {
    case .local(let root):
      for path in paths { stamps[path] = try? Self.localStamp(root: root, path: path) }
    case .remote(let source, let root):
      guard let client else { throw BridgeError("Remote document access is unavailable.") }
      let prefix = (root == "/" ? "" : root) + "/"
      let entries = try await client.documentStats(source: source, root: root, paths: paths.map { prefix + $0 })
      stamps = Dictionary(uniqueKeysWithValues: entries.map { (String($0.path.dropFirst(prefix.count)), $0.fingerprint ?? "") })
    }
    guard generation == token else { return false }
    var changed = false
    for path in paths where cache[path]?.stamp != stamps[path] {
      cache.removeValue(forKey: path); changed = true
    }
    if changed { directories.removeAll() }
    return changed
  }
  private static func descriptor(root: URL, path: String) throws -> Int32 {
    let parts = try normalized(path).split(separator: "/").map(String.init)
    var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
    for (index, part) in parts.enumerated() {
      let next = openat(fd, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0))
      close(fd); fd = next
      guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    }
    return fd
  }
  private static func stamp(_ fd: Int32) throws -> (String, Int) {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw BridgeError("Only regular files can be previewed.") }
    return ("\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_nsec)", Int(info.st_size))
  }
  private static func localStamp(root: URL, path: String) throws -> String {
    let fd = try descriptor(root: root, path: path); defer { close(fd) }
    return try stamp(fd).0
  }
  private static func readLocal(root: URL, path: String, limit: Int) throws -> (Data, String) {
    let fd = try descriptor(root: root, path: path)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    let before = try stamp(fd)
    guard before.1 <= limit else { throw BridgeError("File exceeds the preview limit.") }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit, try stamp(fd).0 == before.0 else { throw BridgeError("File is changing. Retry shortly.") }
    return (data, before.0)
  }
}
