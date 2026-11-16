import Foundation

/// A fresh filesystem snapshot for one physical member of a logical asset.
public struct AssetFile: Hashable, Sendable {
  public let url: URL
  public let relativePath: String
  public let size: Int64
  public let modifiedAt: Date?
  public let identifier: String?

  public init(url: URL, relativePath: String, size: Int64, modifiedAt: Date?, identifier: String?) {
    self.url = url; self.relativePath = relativePath; self.size = size
    self.modifiedAt = modifiedAt; self.identifier = identifier
  }

  public static func snapshot(_ url: URL, relativePath: String) throws -> AssetFile {
    var fresh = url; fresh.removeAllCachedResourceValues()
    let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
      .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw AssetError("Not a regular file: \(relativePath)")
    }
    return AssetFile(url: url.resolvingSymlinksInPath(), relativePath: relativePath, size: Int64(values.fileSize ?? 0),
      modifiedAt: values.contentModificationDate,
      identifier: values.fileResourceIdentifier.map { String(describing: $0) })
  }

  public func validate() throws {
    let fresh = try Self.snapshot(url, relativePath: relativePath)
    guard size == fresh.size, modifiedAt == fresh.modifiedAt,
          identifier == nil || identifier == fresh.identifier else {
      throw AssetError("\(relativePath) changed since it was scanned. Refresh before continuing.")
    }
    guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
      throw AssetError("A symbolic link is part of this file's path: \(relativePath)")
    }
  }

  public var contentID: String { "\(relativePath)|\(modifiedAt?.timeIntervalSince1970 ?? 0)|\(size)|\(identifier ?? "")" }
}

public struct AssetError: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

enum AssetPaths {
  static func exists(_ url: URL) -> Bool {
    // lstat-style attributes also recognize a dangling symlink as occupied.
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }
  static func below(_ root: URL, relativePath: String) throws -> URL {
    let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          !relativePath.contains("\0") else { throw AssetError("Invalid relative asset path.") }
    let result = root.resolvingSymlinksInPath().appendingPathComponent(relativePath).standardizedFileURL
    guard result.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
          result == result.resolvingSymlinksInPath().standardizedFileURL else {
      throw AssetError("Asset path crosses a symbolic link or leaves its folder.")
    }
    return result
  }
}
