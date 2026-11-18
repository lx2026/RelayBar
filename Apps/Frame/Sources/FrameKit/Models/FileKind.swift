import Foundation

/// A subfolder shown as a tile in Icons mode.
public struct FolderTile: Identifiable, Hashable, Sendable {
  public let path: String
  public let name: String
  public var id: String { path }
  public init(path: String, name: String) {
    self.path = path
    self.name = name
  }
}

extension PhotoItem {
  /// The short kind label shown in chips: the extension in capitals, MD for Markdown and HTML for HTM.
  public var kindChip: String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "": return "FILE"
    case "markdown": return "MD"
    case "htm": return "HTML"
    case "jpeg": return "JPG"
    default: return String(ext.uppercased().prefix(5))
    }
  }

  /// The kind in words, as the details rail's last line gives it.
  public var kindDescription: String {
    if format.isImage { return "\(kindChip) image" }
    if format.isVideo { return "\(kindChip) video" }
    switch format {
    case .markdown: return "Markdown document"
    case .html: return "HTML document"
    case .text: return "\(kindChip) text"
    default: return "\(kindChip) file"
    }
  }
}

extension FileTypeFilter {
  /// The kind filter's own wording, where "All kinds" stands for every file.
  public var kindTitle: String { self == .all ? "All kinds" : rawValue }
}
