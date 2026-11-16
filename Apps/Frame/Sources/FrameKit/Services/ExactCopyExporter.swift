import Foundation

public enum ExportError: LocalizedError {
  case sourceAndDestinationMatch

  public var errorDescription: String? {
    switch self {
    case .sourceAndDestinationMatch:
      return "Choose a destination different from the source file."
    }
  }
}

public enum ExactCopyExporter {
  public static func export(source: URL, destination: URL, fileManager: FileManager = .default)
    throws
  {
    let source = source.standardizedFileURL
    let destination = destination.standardizedFileURL
    guard source.path != destination.path else { throw ExportError.sourceAndDestinationMatch }
    guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
      throw ExportError.sourceAndDestinationMatch
    }
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
    if let a = try? source.resourceValues(forKeys: keys),
       let b = try? destination.resourceValues(forKeys: keys),
       let ai = a.fileResourceIdentifier as? NSObject,
       let bi = b.fileResourceIdentifier as? NSObject,
       let av = a.volumeIdentifier as? NSObject,
       let bv = b.volumeIdentifier as? NSObject, ai == bi, av == bv {
      throw ExportError.sourceAndDestinationMatch
    }

    let temporaryName = ".\(destination.lastPathComponent).frame-export-\(UUID().uuidString)"
    let temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(temporaryName)

    do {
      try fileManager.copyItem(at: source, to: temporaryURL)
      if fileManager.fileExists(atPath: destination.path) {
        _ = try fileManager.replaceItemAt(
          destination,
          withItemAt: temporaryURL,
          backupItemName: nil,
          options: [.usingNewMetadataOnly]
        )
      } else {
        try fileManager.moveItem(at: temporaryURL, to: destination)
      }
    } catch {
      if fileManager.fileExists(atPath: temporaryURL.path) {
        try? fileManager.removeItem(at: temporaryURL)
      }
      throw error
    }
  }
}
