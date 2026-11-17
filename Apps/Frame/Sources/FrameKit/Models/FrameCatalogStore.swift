import Foundation
import SwiftData

/// Frame's catalog: recent folders, favourites, and the folder baselines and opened times beside them.
/// Models are only ever added. SwiftData adds a new model's table to an existing store when it opens it and
/// leaves the existing rows alone; the store is never deleted or replaced.
public enum FrameCatalogStore {
  public static let schema = Schema([LibraryRootRecord.self, FavoriteRecord.self, OpenedFileRecord.self, FolderBaselineRecord.self])

  /// Opens the catalog at its usual place in Application Support, or at `url`.
  public static func open(at url: URL? = nil) throws -> ModelContainer {
    guard let url else { return try ModelContainer(for: schema) }
    return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
  }
}
