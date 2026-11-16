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
