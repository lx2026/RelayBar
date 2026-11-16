import BridgeProtocol
import CryptoKit
import Foundation

/// Session-only derivatives and metadata; never reloads a previous session's index.
public actor RemotePreviewCache {
  private let root: URL
  private let limit: Int64
  private var index: [URL: (Int64, Date)] = [:]
  public init(root: URL? = nil, limit: Int64 = 512 * 1_024 * 1_024) {
    self.root = root ?? RemoteSessionStorage.root.appendingPathComponent("Previews-\(UUID())", isDirectory: true)
    self.limit = limit
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  public func clear() {
    index.removeAll()
    try? FileManager.default.removeItem(at: root)
  }
  private func url(_ key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return root.appendingPathComponent(digest + ".json")
  }
  public func read(_ key: String) -> BridgeAssetResult? {
    let file = url(key)
    guard index[file] != nil,
          let value = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
          value.isRegularFile == true, value.isSymbolicLink != true, (value.fileSize ?? Int.max) <= 8 * 1_024 * 1_024,
          let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(BridgeAssetResult.self, from: data),
          result.error == nil, result.fingerprint != nil else { return nil }
    index[file] = (Int64(data.count), .now)
    return result
  }
  public func write(_ result: BridgeAssetResult, key: String) throws {
    guard result.error == nil, result.fingerprint != nil else { return }
    let data = try JSONEncoder().encode(result)
    guard data.count <= 8 * 1_024 * 1_024 else { throw BridgeError("Remote preview is too large to cache.") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw BridgeError("Unsafe preview cache.") }
    let file = url(key)
    try data.write(to: file, options: .atomic)
    index[file] = (Int64(data.count), .now)
    var total = index.values.reduce(Int64(0)) { $0 + $1.0 }, count = index.count
    guard total > limit || count > 5_000 else { return }
    for (url, value) in index.sorted(by: { $0.value.1 < $1.value.1 }) where total > limit || count > 5_000 {
      try FileManager.default.removeItem(at: url); total -= value.0; count -= 1; index.removeValue(forKey: url)
    }
  }
}
