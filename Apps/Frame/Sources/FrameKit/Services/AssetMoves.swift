import Foundation

public struct MovedAssetFile: Sendable {
  public let original: AssetFile
  public let moved: AssetFile
}

struct AssetMoveResult {
  var moved: [MovedAssetFile]
  var error: String?
}

/// Best-effort grouped moves. Residuals are never discarded if rollback fails.
enum AssetMoves {
  static func move(_ members: [AssetFile], operation: (URL) throws -> URL) -> AssetMoveResult {
    var moved: [MovedAssetFile] = []
    do {
      for member in members { try member.validate() }
      for member in members {
        let destination = try operation(member.url)
        // The operation has moved the file even if snapshot retrieval now fails.
        let snapshot = (try? AssetFile.snapshot(destination, relativePath: member.relativePath))
          ?? AssetFile(url: destination, relativePath: member.relativePath, size: member.size,
                       modifiedAt: member.modifiedAt, identifier: member.identifier)
        moved.append(MovedAssetFile(original: member, moved: snapshot))
      }
      return AssetMoveResult(moved: moved, error: nil)
    } catch {
      let reason = error.localizedDescription
      var residuals: [MovedAssetFile] = []
      for move in moved.reversed() {
        do {
          try move.moved.validate()
          guard !AssetPaths.exists(move.original.url) else { throw CocoaError(.fileWriteFileExists) }
          try FileManager.default.moveItem(at: move.moved.url, to: move.original.url)
        } catch { residuals.append(move) }
      }
      let recovery = residuals.isEmpty ? "" : " Recovery files: " + residuals.map { $0.moved.url.path }.joined(separator: ", ")
      return AssetMoveResult(moved: residuals.reversed(), error: reason + recovery)
    }
  }
}
