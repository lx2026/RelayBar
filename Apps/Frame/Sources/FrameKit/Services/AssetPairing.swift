import AssetGrouping
import Foundation

public enum AssetPairing {
  /// Match all same-folder companions using the shared local/remote filename rule.
  public static func pair(_ photos: [PhotoItem], sidecars: [AssetFile]) -> [PhotoItem] {
    let groups = AssetCompanionNames.groups(media: photos.map(\.relativePath), files: sidecars.map(\.relativePath))
    let files = Dictionary(sidecars.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    return photos.map { photo in
      var photo = photo
      photo.companions = (groups[photo.relativePath] ?? []).compactMap { files[$0] }
      return photo
    }
  }
}
