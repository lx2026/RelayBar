import Foundation

public enum PhotoFormat: String, Codable, CaseIterable, Sendable {
  case jpeg = "JPEG"
  case png = "PNG"
  case mp4 = "MP4"
  case mov = "MOV"
  case m4v = "M4V"
  case markdown = "Markdown"
  case html = "HTML"
  case text = "Text"
  case file = "File"

  public var isVideo: Bool { self == .mp4 || self == .mov || self == .m4v }
  public var isImage: Bool { self == .jpeg || self == .png }
  public var isMedia: Bool { isImage || isVideo }
  public var isDocument: Bool { !isMedia }
  public var symbol: String { isVideo ? "play.rectangle" : isImage ? "photo" : self == .html ? "globe" : self == .file ? "doc" : "doc.text" }

  public init?(pathExtension: String) {
    switch pathExtension.lowercased() {
    case "jpg", "jpeg": self = .jpeg
    case "png": self = .png
    case "mp4": self = .mp4
    case "mov": self = .mov
    case "m4v": self = .m4v
    case "md", "markdown": self = .markdown
    case "html", "htm": self = .html
    default: return nil
    }
  }

  public static let textExtensions: Set<String> = ["txt", "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "xml", "log",
    "css", "js", "ts", "jsx", "tsx", "py", "swift", "sh", "rb", "rs", "go",
    "c", "h", "cpp", "hpp", "java", "sql", "ini", "conf"]

  public static func browsing(pathExtension: String) -> Self {
    if let format = Self(pathExtension: pathExtension) { return format }
    return textExtensions.contains(pathExtension.lowercased()) ? .text : .file
  }
}

public struct PhotoItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let rootID: UUID
  public let url: URL
  public let relativePath: String
  public let folderRelativePath: String
  public let name: String
  public let format: PhotoFormat
  public let fileSize: Int64
  public let createdAt: Date?
  public let modifiedAt: Date?
  public let fileIdentifier: String?
  public var companions: [AssetFile]
  /// The first JSON supplies the generation summary; every companion remains in the group.
  public var sidecar: AssetFile? { companions.first { $0.url.pathExtension.lowercased() == "json" } }
  public var archiveID: UUID?
  public var archiveManifest: AssetFile?
  public var remote: RemoteAssetReference?
  public var companionOwnerID: String?
  public var favoriteID: String { archiveID == nil ? id : FavoriteRecord.makeKey(rootID: rootID, relativePath: relativePath) }

  public var mediaFile: AssetFile { AssetFile(url: url, relativePath: relativePath, size: fileSize,
    modifiedAt: modifiedAt, identifier: fileIdentifier) }
  public var exportMembers: [AssetFile] { [mediaFile] + companions }
  public var fileMembers: [AssetFile] { exportMembers + (archiveManifest.map { [$0] } ?? []) }
  public var metadataContentID: String { contentID + "|" + companions.map(\.contentID).joined(separator: "|") }

  public var contentID: String { "\(id)|\(modifiedAt?.timeIntervalSince1970 ?? 0)|\(fileSize)|\(remote?.listingID.uuidString ?? "")" }

  public init(
    id: String,
    rootID: UUID,
    url: URL,
    relativePath: String,
    folderRelativePath: String,
    name: String,
    format: PhotoFormat,
    fileSize: Int64,
    createdAt: Date?,
    modifiedAt: Date?,
    fileIdentifier: String?,
    companions: [AssetFile] = [],
    archiveID: UUID? = nil,
    archiveManifest: AssetFile? = nil
  ) {
    self.id = id
    self.rootID = rootID
    self.url = url
    self.relativePath = relativePath
    self.folderRelativePath = folderRelativePath
    self.name = name
    self.format = format
    self.fileSize = fileSize
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.fileIdentifier = fileIdentifier
    self.companions = companions
    self.archiveID = archiveID
    self.archiveManifest = archiveManifest
  }
}

public struct FolderNode: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let relativePath: String
  public let photoCount: Int
  public let children: [FolderNode]

  public init(
    id: String, name: String, relativePath: String, photoCount: Int, children: [FolderNode]
  ) {
    self.id = id
    self.name = name
    self.relativePath = relativePath
    self.photoCount = photoCount
    self.children = children
  }
}

public enum PhotoFilter: String, CaseIterable, Identifiable, Sendable {
  case all = "All"
  case favorites = "Favorites"
  case notFavorited = "Hide favorites"
  case archive = "Archive"

  public var id: String { rawValue }
}

public enum FileTypeFilter: String, CaseIterable, Identifiable, Sendable {
  case all = "All files"
  case images = "Images"
  case videos = "Videos"
  case documents = "Documents"
  case other = "Other files"

  public var id: String { rawValue }
  public func includes(_ format: PhotoFormat) -> Bool {
    switch self {
    case .all: true
    case .images: format.isImage
    case .videos: format.isVideo
    case .documents: format == .markdown || format == .html || format == .text
    case .other: format == .file
    }
  }
}
