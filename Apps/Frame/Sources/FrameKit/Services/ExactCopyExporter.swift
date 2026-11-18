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
  /// Copies to a temporary file beside `destination`, then publishes it. With `replacing` false nothing at the
  /// destination is ever replaced: an item that appears there during the copy is reported as a collision.
  public static func export(source: URL, destination: URL, fileManager: FileManager = .default, replacing: Bool = true)
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
      if !replacing {
        try publishExclusively(temporaryURL, at: destination)
      } else if fileManager.fileExists(atPath: destination.path) {
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

  /// Renames only if the name is free. A volume that cannot rename exclusively gets a hard link instead, and one
  /// with neither an exclusive create; each fails when the name is taken, so an existing item is never touched.
  private static func publishExclusively(_ temporary: URL, at destination: URL) throws {
    var code: Int32 = temporary.withUnsafeFileSystemRepresentation { from in
      destination.withUnsafeFileSystemRepresentation { to in
        guard let from, let to else { return EINVAL }
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
        guard errno == ENOTSUP else { return errno }
        guard link(from, to) == 0 else { return errno }
        unlink(from)
        return 0
      }
    }
    // FAT and exFAT, for example, support neither; the name is then claimed by an exclusive create.
    if code == ENOTSUP { code = copyExclusively(temporary, to: destination) }
    guard code != 0 else { return }
    let info: [String: Any] = [NSFilePathErrorKey: destination.path, NSURLErrorKey: destination]
    if code == EEXIST { throw CocoaError(.fileWriteFileExists, userInfo: info) }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: info)
  }

  /// Creates `destination` only if the name is free, copies `temporary` into it and removes `temporary`. Returns 0
  /// or the error number. On failure only the file this call created is removed.
  static func copyExclusively(_ temporary: URL, to destination: URL) -> Int32 {
    temporary.withUnsafeFileSystemRepresentation { from in
      destination.withUnsafeFileSystemRepresentation { to in
        guard let from, let to else { return EINVAL }
        let source = open(from, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { return errno }
        defer { close(source) }
        let target = open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard target >= 0 else { return errno }
        defer { close(target) }
        guard fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
          let code = errno
          var made = stat(), named = stat()
          if fstat(target, &made) == 0, lstat(to, &named) == 0, made.st_dev == named.st_dev, made.st_ino == named.st_ino { unlink(to) }
          return code
        }
        unlink(from)
        return 0
      }
    }
  }
}
