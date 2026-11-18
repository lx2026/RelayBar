import BridgeProtocol
import Combine
import Composition
import CoreServices
import Foundation

/// Metadata for expanded directories only. FSEvents reconciles changed branches, never rescans the root.
@MainActor public final class LocalFolderIndex: ObservableObject {
  public let root: URL
  public let rootID: UUID
  @Published public private(set) var results: [String: ScanResult] = [:]
  @Published public private(set) var expanded: Set<String> = [""]
  @Published public private(set) var loading: Set<String> = []
  @Published public private(set) var errors: [String: String] = [:]
  public private(set) var revision = 0
  private var stopped = false
  public var isStopped: Bool { stopped }
  private let authorize: @MainActor () throws -> Void
  var didShutdown: (() -> Void)?
  private let work = EffectScope()
  private var retirement: Task<Void, Never>?
  public var onChange: ((String, ScanResult) -> Void)?
  public var onFilesChanged: (() -> Void)?
  private var tasks: [String: Task<ScanResult, Error>] = [:]
  private var watcher: FolderWatcher?
  public init(root: URL, rootID: UUID, authorize: @escaping @MainActor () throws -> Void = {}) {
    self.root = root; self.rootID = rootID
    self.authorize = authorize
    watcher = FolderWatcher(root: root) { [weak self] paths in
      MainActor.assumeIsolated {
        guard let self, !self.stopped else { return }
        _ = try? self.work.task { [weak self] in await self?.changed(paths) }
      }
    }
  }
  public func stop() {
    guard !stopped else { return }
    stopped = true; watcher?.stop(); watcher = nil; work.invalidate()
    onChange = nil; onFilesChanged = nil
    let pending = Array(tasks.values)
    for task in pending { task.cancel() }
    tasks.removeAll(); loading.removeAll()
    retirement = Task {
      await work.dispose()
      for task in pending { _ = try? await task.value }
      didShutdown?(); didShutdown = nil
    }
  }
  public func shutdown() async { stop(); await retirement?.value }
  public func reveal(_ path: String) {
    var parent = path
    while !parent.isEmpty { expanded.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
    expanded.insert("")
  }
  public func toggle(_ path: String) {
    if expanded.remove(path) == nil { expanded.insert(path); _ = try? work.task { _ = try? await self.load(path) } }
  }
  @discardableResult public func load(_ path: String, force: Bool = false) async throws -> ScanResult {
    guard !stopped else { throw CancellationError() }
    try authorize()
    if !force, let result = results[path] { return result }
    if let task = tasks[path] {
      let result = try await task.value
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      try authorize()
      return result
    }
    guard results[path] != nil || results.count < 64 else { throw BridgeError("Folder tree limit reached. Open a smaller folder.") }
    let root = root, rootID = rootID
    let task = Task { [work] in
      try await work.run {
        let reader = Task.detached(priority: .userInitiated) { try FileScanner.directory(rootURL: root, rootID: rootID, path: path) }
        return try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
      }
    }
    tasks[path] = task; loading.insert(path)
    defer { tasks.removeValue(forKey: path); loading.remove(path) }
    do {
      let value = try await task.value
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      try authorize()
      guard results.values.reduce(0, { $0 + $1.files.count }) - (results[path]?.files.count ?? 0) + value.files.count <= 20_000 else {
        throw BridgeError("Folder tree limit reached. Open a smaller folder.")
      }
      revision += 1; results[path] = value; errors.removeValue(forKey: path); onChange?(path, value)
      return value
    } catch { if !stopped { revision += 1; errors[path] = error.localizedDescription }; throw error }
  }
  private func changed(_ paths: [String]) async {
    guard !stopped else { return }
    onFilesChanged?()
    let rootPath = root.path
    let affected = Set(paths.compactMap { path -> String? in
      let event = URL(fileURLWithPath: path)
      let path = event.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(event.lastPathComponent).path
      guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
      return path == rootPath ? "" : String(path.dropFirst(rootPath.count + 1))
    })
    let targets = results.keys.filter { folder in
      paths.contains("") || affected.contains(folder) || affected.contains { ($0 as NSString).deletingLastPathComponent == folder }
    }
    for path in targets { _ = try? await load(path, force: true) }
  }
}

private final class FolderWatcher {
  private var stream: FSEventStreamRef?
  private let change: ([String]) -> Void
  init(root: URL, change: @escaping ([String]) -> Void) {
    self.change = change
    var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    stream = FSEventStreamCreate(nil, { _, context, count, paths, flags, _ in
      guard let context else { return }
      let owner = Unmanaged<FolderWatcher>.fromOpaque(context).takeUnretainedValue()
      let values = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      var changed = (0..<count).map { String(cString: values[$0]) }
      if (0..<count).contains(where: { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 }) { changed.append("") }
      owner.change(changed)
    }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
    if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
  }
  func stop() {
    if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    stream = nil
  }
  deinit { stop() }
}
