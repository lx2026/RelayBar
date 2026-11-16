import Foundation

public struct RemoteScanSnapshot: Sendable {
  public let photos: [PhotoItem]
  public let files: [PhotoItem]
  public let folders: Int
  public let issues: [String]
  public let finished: Bool
}

public enum RemoteSubfolderScan {
  /// Breadth-first, one directory request at a time. No file contents are fetched here.
  @MainActor public static func run(index: RemoteFolderIndex, path: String,
    maximumFolders: Int = RemoteFolderIndex.maximumFolders,
    maximumAssets: Int = RemoteFolderIndex.maximumAssets,
    publish: (RemoteScanSnapshot) -> Void) async throws {
    var queue: [(String, Int)] = [(path, 0)], cursor = 0, folders = 0
    var photos: [PhotoItem] = [], files: [PhotoItem] = [], issues: [String] = []
    var lastPublish = ContinuousClock.now
    while cursor < queue.count {
      try Task.checkCancellation()
      guard folders < maximumFolders else {
        issues.append("Stopped at \(maximumFolders) folders. Choose a smaller folder to continue."); break
      }
      let (current, depth) = queue[cursor]; cursor += 1; folders += 1
      do {
        let result = try await index.load(current)
        try Task.checkCancellation()
        let remaining = max(0, maximumAssets - files.count)
        let admitted = Array(result.files.prefix(remaining)), ids = Set(admitted.map(\.id))
        files.append(contentsOf: admitted)
        photos.append(contentsOf: result.photos.filter { ids.contains($0.id) })
        if result.files.count > remaining || (files.count == maximumAssets && (!result.rootFolder.children.isEmpty || cursor < queue.count)) {
          issues.append("Stopped at \(maximumAssets) files. Choose a smaller folder to continue."); break
        }
        if depth < RemoteFolderIndex.maximumDepth {
          // Queue only as many paths as can actually be visited, plus one sentinel for the limit notice.
          let room = max(0, maximumFolders + 1 - queue.count)
          queue.append(contentsOf: result.rootFolder.children.prefix(room).map { ($0.relativePath, depth + 1) })
        } else if !result.rootFolder.children.isEmpty {
          issues.append("Depth limit reached at \(current). Open that folder to continue.")
        }
      } catch is CancellationError { throw CancellationError() }
      catch {
        issues.append("\(current): \(error.localizedDescription)")
        // Don't hammer an offline host hundreds of times after repeated failures.
        if issues.count >= 3 { issues.append("Stopped after three folder errors. Refresh to retry."); break }
      }
      if folders == 1 || lastPublish.duration(to: .now) >= .milliseconds(150) {
        publish(RemoteScanSnapshot(photos: photos, files: files, folders: folders, issues: issues, finished: false))
        lastPublish = .now
      }
    }
    try Task.checkCancellation()
    publish(RemoteScanSnapshot(photos: photos, files: files, folders: folders, issues: issues, finished: true))
  }
}
