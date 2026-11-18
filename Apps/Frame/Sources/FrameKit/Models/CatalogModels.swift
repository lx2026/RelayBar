import Foundation
import SwiftData

@Model
public final class LibraryRootRecord {
  @Attribute(.unique) public var id: UUID
  public var displayName: String
  public var bookmarkData: Data
  public var lastOpenedAt: Date

  public init(id: UUID, displayName: String, bookmarkData: Data, lastOpenedAt: Date = .now) {
    self.id = id
    self.displayName = displayName
    self.bookmarkData = bookmarkData
    self.lastOpenedAt = lastOpenedAt
  }
}

@Model
public final class FavoriteRecord {
  @Attribute(.unique) public var key: String
  public var rootID: UUID
  public var relativePath: String
  public var isFavorite: Bool

  public init(rootID: UUID, relativePath: String, isFavorite: Bool) {
    self.key = Self.makeKey(rootID: rootID, relativePath: relativePath)
    self.rootID = rootID
    self.relativePath = relativePath
    self.isFavorite = isFavorite
  }

  public static func makeKey(rootID: UUID, relativePath: String) -> String {
    "\(rootID.uuidString):\(relativePath)"
  }
}

/// The modification time a file had when it was last shown in Files mode, keyed like `FavoriteRecord`.
/// `held` keeps the entry while Frame itself has moved the file away (Trash or Archive), so Undo and Restore
/// bring the file back without a marker.
@Model
public final class OpenedFileRecord {
  @Attribute(.unique) public var key: String
  public var rootID: UUID
  public var relativePath: String
  public var openedAt: Date
  public var held = false

  public init(rootID: UUID, relativePath: String, openedAt: Date) {
    self.key = FavoriteRecord.makeKey(rootID: rootID, relativePath: relativePath)
    self.rootID = rootID
    self.relativePath = relativePath
    self.openedAt = openedAt
  }
}

/// The newest modification time among a folder's files when a build that marks changed files first listed it.
/// Files at or before it are never marked. Keyed like `FavoriteRecord`, with the folder's path.
@Model
public final class FolderBaselineRecord {
  @Attribute(.unique) public var key: String
  public var rootID: UUID
  public var folderPath: String
  public var baseline: Date

  public init(rootID: UUID, folderPath: String, baseline: Date) {
    self.key = FavoriteRecord.makeKey(rootID: rootID, relativePath: folderPath)
    self.rootID = rootID
    self.folderPath = folderPath
    self.baseline = baseline
  }
}
