import AssetGrouping
import Foundation

public enum ArchiveService {
  private static let marker = "Frame Archive 1\n"
  private static let manifestName = ".frame-asset.json"

  private struct Member: Codable {
    let path: String
    let size: Int64
    let modifiedAt: Date?
    let identifier: String?
    init(_ file: AssetFile) {
      path = file.relativePath; size = file.size; modifiedAt = file.modifiedAt; identifier = file.identifier
    }
    func file(at url: URL) -> AssetFile {
      AssetFile(url: url, relativePath: path, size: size, modifiedAt: modifiedAt, identifier: identifier)
    }
  }
  private struct Record: Codable {
    let version: Int
    let id: UUID
    let createdAt: Date?
    let members: [Member]
  }

  public static func isManaged(_ archive: URL) -> Bool {
    guard (try? archive.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
          let file = try? AssetFile.snapshot(archive.appendingPathComponent(".frame-archive"), relativePath: ".frame-archive"),
          file.size < 1_024 else { return false }
    return (try? String(contentsOf: file.url, encoding: .utf8)) == marker
  }

  private static func prepare(root: URL) throws -> URL {
    let archive = try AssetPaths.below(root, relativePath: "Archive")
    if AssetPaths.exists(archive) {
      guard isManaged(archive) else { throw AssetError("Archive already exists and was not created by Frame. Rename that folder in Finder or choose another root; nothing was moved.") }
      return archive
    }
    let stage = root.resolvingSymlinksInPath().appendingPathComponent(".frame-archive-\(UUID())")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    do {
      try Data(marker.utf8).write(to: stage.appendingPathComponent(".frame-archive"), options: .withoutOverwriting)
      try FileManager.default.moveItem(at: stage, to: archive)
      return archive
    } catch {
      try? FileManager.default.removeItem(at: stage) // Only this operation's newly created metadata directory.
      throw error
    }
  }

  public static func archive(_ photo: PhotoItem, root: URL,
    move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
    guard photo.remote == nil, photo.url.isFileURL else { throw AssetError("Remote assets must be moved through RelayBar.") }
    guard photo.archiveID == nil else { throw AssetError("This asset is already archived.") }
    for member in photo.exportMembers {
      guard try AssetPaths.below(root, relativePath: member.relativePath) == member.url.standardizedFileURL else {
        throw AssetError("Asset is outside this folder.")
      }
      try member.validate()
    }
    let archive = try prepare(root: root)
    let volume = try FileManager.default.attributesOfFileSystem(forPath: archive.path)[.systemNumber] as? NSNumber
    for member in photo.exportMembers {
      let memberVolume = try FileManager.default.attributesOfFileSystem(forPath: member.url.path)[.systemNumber] as? NSNumber
      guard let volume, volume == memberVolume else { throw AssetError("Archive cannot move across volumes. Choose the folder on the same volume as this asset.") }
    }
    let id = UUID()
    let directory = archive.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let record = Record(version: 1, id: id, createdAt: photo.createdAt, members: photo.exportMembers.map(Member.init))
    // Durable intent precedes the first rename. Restore also handles an interrupted move.
    try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
    let result = AssetMoves.move(photo.exportMembers) { source in
      let destination = directory.appendingPathComponent(source.lastPathComponent)
      guard !AssetPaths.exists(destination) else { throw CocoaError(.fileWriteFileExists) }
      try move(source, destination)
      return destination
    }
    if let error = result.error {
      if result.moved.isEmpty { try? FileManager.default.removeItem(at: directory) }
      throw AssetError(error)
    }
  }

  public static func load(root: URL, rootID: UUID) -> (photos: [PhotoItem], warnings: [String]) {
    let archive = root.resolvingSymlinksInPath().appendingPathComponent("Archive")
    guard isManaged(archive) else { return ([], []) }
    var photos: [PhotoItem] = [], warnings: [String] = []
    do {
      let folders = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      guard folders.count <= 10_000 else { throw AssetError("Archive exceeds 10,000 entries. Open it in Finder to manage it.") }
      for folder in folders {
        do {
          let (record, files, manifest) = try read(folder, root: root)
          guard let media = files.first, let format = PhotoFormat(pathExtension: media.url.pathExtension) else { throw AssetError("Unsupported archive entry.") }
          let original = record.members[0].path
          photos.append(PhotoItem(id: "\(rootID):archive:\(record.id)", rootID: rootID,
            url: media.url, relativePath: original, folderRelativePath: (original as NSString).deletingLastPathComponent,
            name: (original as NSString).lastPathComponent, format: format, fileSize: media.size,
            createdAt: record.createdAt, modifiedAt: media.modifiedAt, fileIdentifier: media.identifier,
            companions: Array(files.dropFirst()), archiveID: record.id, archiveManifest: manifest))
          if files.contains(where: { !$0.url.path.hasPrefix(folder.path + "/") }) {
            warnings.append("Interrupted archive: \(original). Select it in Archive and choose Restore to finish recovery.")
          }
        } catch { warnings.append("Archive recovery needed at \(folder.path): \(error.localizedDescription)") }
      }
    } catch { warnings.append(error.localizedDescription) }
    return (photos.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }, warnings)
  }

  private static func read(_ folder: URL, root: URL) throws -> (Record, [AssetFile], AssetFile) {
    guard let id = UUID(uuidString: folder.lastPathComponent),
          folder.standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path else { throw AssetError("Unrecognized archive directory.") }
    let manifest = try AssetFile.snapshot(folder.appendingPathComponent(manifestName), relativePath: "Archive/\(id)/\(manifestName)")
    guard manifest.size <= 2 * 1_024 * 1_024 else { throw AssetError("Invalid archive record.") }
    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: manifest.url))
    guard record.version == 1, record.id == id, (1...10_000).contains(record.members.count),
          Set(record.members.map { ($0.path as NSString).lastPathComponent }).count == record.members.count,
          PhotoFormat(pathExtension: (record.members[0].path as NSString).pathExtension) != nil else {
      throw AssetError("Invalid archive members.")
    }
    let paths = record.members.map(\.path)
    guard AssetCompanionNames.groups(media: [paths[0]], files: Array(paths.dropFirst()))[paths[0], default: []].count == paths.count - 1,
          paths.dropFirst().allSatisfy({ !AssetCompanionNames.isMedia($0) }) else {
      throw AssetError("Invalid companion files.")
    }
    let files = try record.members.map { member -> AssetFile in
      let original = try AssetPaths.below(root, relativePath: member.path)
      guard !member.path.hasPrefix("Archive/") else { throw AssetError("Nested archive entries are not supported.") }
      let stored = folder.appendingPathComponent((member.path as NSString).lastPathComponent)
      let file = member.file(at: AssetPaths.exists(stored) ? stored : original)
      try file.validate()
      return file
    }
    return (record, files, manifest)
  }

  public static func restore(_ photo: PhotoItem, root: URL,
    move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
    guard let id = photo.archiveID else { throw AssetError("This asset is not archived.") }
    let archive = try AssetPaths.below(root, relativePath: "Archive")
    guard isManaged(archive) else { throw AssetError("Archive is unavailable.") }
    let folder = archive.appendingPathComponent(id.uuidString)
    let (_, files, _) = try read(folder, root: root)
    let pending = files.filter { $0.url.path.hasPrefix(folder.path + "/") }
    var destinations: [URL: URL] = [:]
    for member in pending {
      let destination = try AssetPaths.below(root, relativePath: member.relativePath)
      guard !AssetPaths.exists(destination) else { throw AssetError("Restore stopped: \(member.relativePath) already exists. No files were replaced.") }
      destinations[member.url] = destination
    }
    for destination in destinations.values {
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let sourceVolume = try FileManager.default.attributesOfFileSystem(forPath: folder.path)[.systemNumber] as? NSNumber
    for destination in destinations.values {
      let targetVolume = try FileManager.default.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)[.systemNumber] as? NSNumber
      guard let sourceVolume, sourceVolume == targetVolume else { throw AssetError("Restore cannot move across volumes. No files were moved.") }
    }
    let result = AssetMoves.move(pending) { source in
      let destination = destinations[source]!
      guard !AssetPaths.exists(destination) else { throw CocoaError(.fileWriteFileExists) }
      try move(source, destination)
      return destination
    }
    if let error = result.error { throw AssetError(error) }
    // Remove only the known manifest; never recursively delete unrecognized added files.
    try FileManager.default.removeItem(at: folder.appendingPathComponent(manifestName))
    if try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty { try FileManager.default.removeItem(at: folder) }
  }
}
