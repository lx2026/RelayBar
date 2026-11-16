import Foundation

/// Disposable media only. Favorites and folder bookmarks are stored separately.
public enum RemoteSessionStorage {
  public static let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("FrameRemoteSession", isDirectory: true)

  public static func start() {
    clear()
    let oldCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("FrameRemotePreviews-v1", isDirectory: true)
    try? FileManager.default.removeItem(at: oldCache)
  }

  public static func clear() { try? FileManager.default.removeItem(at: root) }
}
