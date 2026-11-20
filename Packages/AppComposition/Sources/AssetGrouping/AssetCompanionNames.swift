import PreviewSupport
import Foundation

/// Shared filename grouping, independent of companion extension or suffix vocabulary.
public enum AssetCompanionNames {
  public static func isDocument(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return PreviewFileTypes.markdown.contains(ext) || PreviewFileTypes.html.contains(ext)
  }
  public static func isPrimary(_ path: String) -> Bool { isMedia(path) || isDocument(path) }
  public static func isMedia(_ path: String) -> Bool {
    isMedia(path, extendedImages: true)
  }
  public static func isMedia(_ path: String, extendedImages: Bool) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return PreviewFileTypes.images(extended: extendedImages).contains(ext) || PreviewFileTypes.video.contains(ext)
  }
  /// Extensions that could own companions when v1 archives were introduced.
  public static let originalArchiveMedia = PreviewFileTypes.coreImages.union(PreviewFileTypes.video)
  public static let originalArchivePrimaries = originalArchiveMedia.union(PreviewFileTypes.html).union(["md", "markdown"])

  public static func validArchiveMembers(_ paths: [String]) -> Bool {
    guard let owner = paths.first, isPrimary(owner) else { return false }
    let files = Array(paths.dropFirst())
    if groups(media: [owner], files: files)[owner, default: []].count == files.count { return true }
    guard originalArchiveMedia.contains((owner as NSString).pathExtension.lowercased()) else { return false }
    let legacy = groups(media: [owner], files: files) { path in
      originalArchivePrimaries.contains((path as NSString).pathExtension.lowercased())
    }
    return legacy[owner, default: []].count == files.count
  }

  /// Longest dot-delimited prefix wins. Full media filenames beat equal stems;
  /// ambiguous stems remain ungrouped. Paths include the folder, preventing cross-folder matches.
  public static func groups(media: [String], files: [String]) -> [String: [String]] {
    groups(media: media, files: files, excluding: isPrimary)
  }

  private static func groups(media: [String], files: [String], excluding primary: (String) -> Bool) -> [String: [String]] {
    let owners = media.filter(isMedia)
    let exact = Set(owners)
    let stems = Dictionary(grouping: owners) { ($0 as NSString).deletingPathExtension }
    var result: [String: [String]] = [:]
    for file in files where !primary(file) && !exact.contains(file) && !(file as NSString).lastPathComponent.hasPrefix(".") {
      var prefix = file
      while !(prefix as NSString).pathExtension.isEmpty {
        prefix = (prefix as NSString).deletingPathExtension
        if exact.contains(prefix) { result[prefix, default: []].append(file); break }
        if let owners = stems[prefix] {
          if owners.count == 1 { result[owners[0], default: []].append(file) }
          break
        }
      }
    }
    for owner in Array(result.keys) {
      let stem = (owner as NSString).deletingPathExtension
      func rank(_ path: String) -> Int {
        guard (path as NSString).pathExtension.lowercased() == "json" else { return 3 }
        let base = (path as NSString).deletingPathExtension
        return base == owner ? 0 : base == stem ? 1 : 2
      }
      result[owner]?.sort { rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1) }
    }
    return result
  }
}
