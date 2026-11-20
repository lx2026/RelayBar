import PreviewSupport
import Foundation

public struct ScanResult: Sendable {
  public let photos: [PhotoItem]
  public let rootFolder: FolderNode
  public let warnings: [String]
  public let files: [PhotoItem]

  public init(photos: [PhotoItem], rootFolder: FolderNode, warnings: [String] = [], files: [PhotoItem]? = nil) {
    self.photos = photos
    self.rootFolder = rootFolder
    self.warnings = warnings
    self.files = files ?? photos
  }
}

public enum FileScanner {
  /// One directory of metadata. No document contents, image decoding or recursive walk.
  public static func directory(rootURL: URL, rootID: UUID, path: String) throws -> ScanResult {
    let folder = path.isEmpty ? rootURL : try AssetPaths.below(rootURL, relativePath: path)
    let urls = try FileManager.default.contentsOfDirectory(at: folder,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey], options: [])
    var photos: [PhotoItem] = [], extras: [AssetFile] = [], children: [FolderNode] = []
    var folderDates: [String: Date] = [:]
    for url in urls {
      try Task.checkCancellation()
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
      if values.isSymbolicLink == true { continue }
      let relative = relativePath(for: url, below: rootURL)
      if values.isDirectory == true {
        if relative == "Archive", ArchiveService.isManaged(url) { continue }
        folderDates[relative] = values.contentModificationDate
        children.append(FolderNode(id: relative, name: url.lastPathComponent, relativePath: relative, photoCount: 0, children: []))
      } else if values.isRegularFile == true {
        let file = try AssetFile.snapshot(url, relativePath: relative)
        if let format = PhotoFormat(pathExtension: url.pathExtension) {
          photos.append(item(file, rootID: rootID, format: format))
        } else { extras.append(file) }
      }
    }
    photos = AssetPairing.pair(photos, sidecars: extras).sorted(by: newestFirst)
    return ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: folder.lastPathComponent,
      relativePath: path, photoCount: photos.count, children: children.sorted {
        FolderListing.precedes(($0.name, true, folderDates[$0.id]?.timeIntervalSince1970),
                               ($1.name, true, folderDates[$1.id]?.timeIntervalSince1970))
      }),
      files: allFiles(photos: photos, extras: extras, rootID: rootID))
  }
  public static func item(_ file: AssetFile, rootID: UUID, format: PhotoFormat = .text) -> PhotoItem {
    PhotoItem(id: FavoriteRecord.makeKey(rootID: rootID, relativePath: file.relativePath), rootID: rootID,
      url: file.url, relativePath: file.relativePath, folderRelativePath: (file.relativePath as NSString).deletingLastPathComponent,
      name: file.url.lastPathComponent, format: format, fileSize: file.size, createdAt: nil,
      modifiedAt: file.modifiedAt, fileIdentifier: file.identifier)
  }
  static func newestFirst(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
    FolderListing.precedes((a.name, false, a.modifiedAt?.timeIntervalSince1970),
                           (b.name, false, b.modifiedAt?.timeIntervalSince1970))
  }

  static func allFiles(photos: [PhotoItem], extras: [AssetFile], rootID: UUID) -> [PhotoItem] {
    let owners = Dictionary(photos.flatMap { photo in photo.companions.map { ($0.relativePath, photo.id) } }, uniquingKeysWith: { first, _ in first })
    return (photos + extras.map { file in
      var value = item(file, rootID: rootID, format: .browsing(pathExtension: file.url.pathExtension))
      value.companionOwnerID = owners[file.relativePath]
      return value
    }).sorted(by: newestFirst)
  }
  public static func scan(rootURL: URL, rootID: UUID) throws -> ScanResult {
    let rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let fileManager = FileManager.default
    let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
    guard rootValues.isDirectory == true, rootValues.isReadable != false else {
      throw CocoaError(.fileReadNoPermission)
    }
    let resourceKeys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .isDirectoryKey,
      .fileSizeKey,
      .creationDateKey,
      .contentModificationDateKey,
      .fileResourceIdentifierKey,
      .isSymbolicLinkKey,
    ]
    let options: FileManager.DirectoryEnumerationOptions = [
      .skipsPackageDescendants,
    ]

    guard
      let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: Array(resourceKeys),
        options: options
      )
    else {
      throw CocoaError(.fileReadNoSuchFile)
    }

    let standardizedRoot = rootURL.standardizedFileURL
    var photos: [PhotoItem] = []
    var sidecars: [AssetFile] = []
    var folderDates: [String: Date] = [:]
    let archiveURL = standardizedRoot.appendingPathComponent("Archive")
    let managedArchive = ArchiveService.isManaged(archiveURL)

    for case let fileURL as URL in enumerator {
      try Task.checkCancellation()
      if managedArchive, fileURL.standardizedFileURL == archiveURL {
        enumerator.skipDescendants(); continue
      }
      let kind = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if kind.isSymbolicLink == true { enumerator.skipDescendants(); continue }
      if kind.isDirectory == true {
        let relative = relativePath(for: fileURL, below: standardizedRoot)
        folderDates[relative] = try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        if fileURL.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants() }
        continue
      }
      guard let format = PhotoFormat(pathExtension: fileURL.pathExtension) else {
        if let file = try? AssetFile.snapshot(fileURL, relativePath: relativePath(for: fileURL, below: standardizedRoot)),
           fileURL.standardizedFileURL == fileURL.resolvingSymlinksInPath().standardizedFileURL {
          sidecars.append(file)
        }
        continue
      }
      let values = try fileURL.resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }

      let relativePath = relativePath(for: fileURL, below: standardizedRoot)
      let folderPath = (relativePath as NSString).deletingLastPathComponent
      let normalizedFolderPath = folderPath == "." ? "" : folderPath
      let identifier = values.fileResourceIdentifier.map { String(describing: $0) }
      let id = FavoriteRecord.makeKey(rootID: rootID, relativePath: relativePath)

      photos.append(
        PhotoItem(
          id: id,
          rootID: rootID,
          url: fileURL,
          relativePath: relativePath,
          folderRelativePath: normalizedFolderPath,
          name: fileURL.lastPathComponent,
          format: format,
          fileSize: Int64(values.fileSize ?? 0),
          createdAt: values.creationDate,
          modifiedAt: values.contentModificationDate,
          fileIdentifier: identifier
        )
      )
    }

    photos.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    photos = AssetPairing.pair(photos, sidecars: sidecars)
    let archive = managedArchive ? ArchiveService.load(root: standardizedRoot, rootID: rootID) : (photos: [], warnings: [])
    // An interrupted grouped move can leave a member at its original location.
    let recoveryURLs = Set(archive.photos.flatMap(\.exportMembers).map(\.url))
    photos.removeAll { recoveryURLs.contains($0.url) }
    sidecars.removeAll { recoveryURLs.contains($0.url) }
    let rootFolder = FolderTreeBuilder.build(rootURL: standardizedRoot, photos: photos, folderDates: folderDates)
    return ScanResult(photos: photos + archive.photos, rootFolder: rootFolder, warnings: archive.warnings,
      files: allFiles(photos: photos, extras: sidecars, rootID: rootID) + archive.photos)
  }

  private static func relativePath(for fileURL: URL, below rootURL: URL) -> String {
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    let filePath = fileURL.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
    return String(filePath.dropFirst(rootPath.count))
  }
}

enum FolderTreeBuilder {
  private final class MutableNode {
    let name: String
    let relativePath: String
    var photoCount = 0
    var children: [String: MutableNode] = [:]

    init(name: String, relativePath: String) {
      self.name = name
      self.relativePath = relativePath
    }
  }

  static func build(rootURL: URL, photos: [PhotoItem], folderDates: [String: Date] = [:]) -> FolderNode {
    let root = MutableNode(name: rootURL.lastPathComponent, relativePath: "")

    for folder in folderDates.keys {
      var node = root, components: [String] = []
      for part in folder.split(separator: "/").map(String.init) {
        components.append(part)
        if node.children[part] == nil { node.children[part] = MutableNode(name: part, relativePath: components.joined(separator: "/")) }
        node = node.children[part]!
      }
    }

    for photo in photos where photo.archiveID == nil {
      root.photoCount += 1
      guard !photo.folderRelativePath.isEmpty else { continue }

      var node = root
      var pathComponents: [String] = []
      for component in NSString(string: photo.folderRelativePath).pathComponents
      where component != "/" {
        pathComponents.append(component)
        let childPath = NSString.path(withComponents: pathComponents)
        if node.children[component] == nil {
          node.children[component] = MutableNode(name: component, relativePath: childPath)
        }
        guard let child = node.children[component] else { continue }
        child.photoCount += 1
        node = child
      }
    }

    return freeze(root, dates: folderDates)
  }

  private static func freeze(_ node: MutableNode, dates: [String: Date]) -> FolderNode {
    let children = node.children.values
      .sorted { FolderListing.precedes(($0.name, true, dates[$0.relativePath]?.timeIntervalSince1970),
                                      ($1.name, true, dates[$1.relativePath]?.timeIntervalSince1970)) }
      .map { freeze($0, dates: dates) }
    return FolderNode(
      id: node.relativePath.isEmpty ? "root" : node.relativePath,
      name: node.name,
      relativePath: node.relativePath,
      photoCount: node.photoCount,
      children: children
    )
  }
}
