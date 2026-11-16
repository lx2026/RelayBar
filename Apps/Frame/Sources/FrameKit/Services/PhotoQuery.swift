import Foundation

public enum PhotoQuery {
  public static func visiblePhotos(
    in photos: [PhotoItem],
    folderRelativePath: String,
    filter: PhotoFilter,
    favorites: Set<PhotoItem.ID>,
    includeSubfolders: Bool = true,
    fileType: FileTypeFilter = .all
  ) -> [PhotoItem] {
    photos.filter { photo in
      let inFolder: Bool
      if !includeSubfolders && filter != .archive {
        inFolder = photo.folderRelativePath == folderRelativePath
      } else if folderRelativePath.isEmpty || folderRelativePath == "/" {
        inFolder = true
      } else {
        inFolder =
          photo.folderRelativePath == folderRelativePath
          || photo.folderRelativePath.hasPrefix(folderRelativePath + "/")
      }
      let favorite = favorites.contains(photo.favoriteID)
      let passesFavorite = (filter != .favorites || favorite) && (filter != .notFavorited || !favorite)
      let passesArchive = (filter == .archive) == (photo.archiveID != nil)
      return inFolder && passesFavorite && passesArchive && fileType.includes(photo.format)
    }
  }
}
