import Foundation

/// Shared filename grouping, independent of companion extension or suffix vocabulary.
public enum AssetCompanionNames {
  public static func isDocument(_ path: String) -> Bool {
    ["md", "markdown", "html", "htm"].contains((path as NSString).pathExtension.lowercased())
  }
  public static func isPrimary(_ path: String) -> Bool { isMedia(path) || isDocument(path) }
  public static func isMedia(_ path: String) -> Bool {
    ["jpg", "jpeg", "png", "mp4", "mov", "m4v"].contains((path as NSString).pathExtension.lowercased())
  }
  /// Longest dot-delimited prefix wins. Full media filenames beat equal stems;
  /// ambiguous stems remain ungrouped. Paths include the folder, preventing cross-folder matches.
  public static func groups(media: [String], files: [String]) -> [String: [String]] {
    let owners = media.filter(isMedia)
    let exact = Set(owners)
    let stems = Dictionary(grouping: owners) { ($0 as NSString).deletingPathExtension }
    var result: [String: [String]] = [:]
    for file in files where !isPrimary(file) && !exact.contains(file) && !(file as NSString).lastPathComponent.hasPrefix(".") {
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
