import Foundation

public struct TrashedFile: Sendable {
  public let photo: PhotoItem
  public let members: [MovedAssetFile]
  public var trashURL: URL { members[0].moved.url }
  public init(photo: PhotoItem, trashURL: URL) {
    self.photo = photo
    let moved = (try? AssetFile.snapshot(trashURL, relativePath: photo.relativePath))
      ?? AssetFile(url: trashURL, relativePath: photo.relativePath, size: photo.fileSize,
                   modifiedAt: photo.modifiedAt, identifier: photo.fileIdentifier)
    members = [MovedAssetFile(original: photo.mediaFile, moved: moved)]
  }
  init(photo: PhotoItem, members: [MovedAssetFile]) { self.photo = photo; self.members = members }
}

public struct FileActionFailure: Identifiable, Sendable {
  public var id: String { photo.id }
  public let photo: PhotoItem
  public let reason: String
  public init(photo: PhotoItem, reason: String) { self.photo = photo; self.reason = reason }
}

public struct TrashBatchResult: Sendable {
  public var successes: [TrashedFile] = []
  public var partialRecoveries: [TrashedFile] = []
  public var failures: [FileActionFailure] = []
  public var unprocessed: [PhotoItem] = []
}

public enum BatchTrash {
  public typealias TrashOperation = @Sendable (URL) throws -> URL
  public static func move(
    _ photos: [PhotoItem],
    operation: TrashOperation = { url in
      var destination: NSURL?
      try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
      guard let result = destination as URL? else { throw CocoaError(.fileWriteUnknown) }
      return result
    },
    progress: @escaping @Sendable (Int) async -> Void = { _ in }
  ) async -> TrashBatchResult {
    var result = TrashBatchResult()
    for (index, photo) in photos.enumerated() {
      if Task.isCancelled { result.unprocessed = Array(photos[index...]); break }
      guard photo.remote == nil, photo.fileMembers.allSatisfy({ $0.url.isFileURL }) else {
        result.failures.append(FileActionFailure(photo: photo, reason: "Remote assets must be moved through RelayBar.")); continue
      }
      let moved = AssetMoves.move(photo.fileMembers, operation: operation)
      if let error = moved.error {
        result.failures.append(FileActionFailure(photo: photo, reason: error))
        if !moved.moved.isEmpty { result.partialRecoveries.append(TrashedFile(photo: photo, members: moved.moved)) }
      } else { result.successes.append(TrashedFile(photo: photo, members: moved.moved)) }
      if index.isMultiple(of: 20) || index == photos.count - 1 { await progress(index + 1) }
    }
    return result
  }

  public static func restore(_ files: [TrashedFile]) -> (restored: [PhotoItem], failed: [TrashedFile], errors: [FileActionFailure]) {
    var restored: [PhotoItem] = []
    var failed: [TrashedFile] = []
    var errors: [FileActionFailure] = []
    for file in files {
      var retryable = true
      do {
        for member in file.members {
          do { try member.moved.validate() }
          catch {
            retryable = false
            throw AssetError("A Trash member is missing or changed. Recovery locations: " + file.members.map { $0.moved.url.path }.joined(separator: ", "))
          }
          guard !AssetPaths.exists(member.original.url) else { throw CocoaError(.fileWriteFileExists) }
        }
        let movedPaths = Set(file.members.map { $0.original.url })
        for member in file.photo.fileMembers where !movedPaths.contains(member.url) { try member.validate() }
        let destinations = Dictionary(uniqueKeysWithValues: file.members.map { ($0.moved.url, $0.original.url) })
        let result = AssetMoves.move(file.members.map(\.moved)) { source in
          let destination = destinations[source]!
          guard !AssetPaths.exists(destination) else { throw CocoaError(.fileWriteFileExists) }
          try FileManager.default.moveItem(at: source, to: destination)
          return destination
        }
        if let error = result.error {
          let returned = Set(result.moved.map { $0.original.url })
          let remaining = file.members.filter { !returned.contains($0.moved.url) }
          if !remaining.isEmpty { failed.append(TrashedFile(photo: file.photo, members: remaining)) }
          retryable = false
          throw AssetError(error)
        }
        restored.append(file.photo)
      } catch {
        if retryable { failed.append(file) }
        errors.append(FileActionFailure(photo: file.photo, reason: error.localizedDescription))
      }
    }
    return (restored, failed, errors)
  }
}
