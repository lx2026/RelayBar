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

/// A file as the file system names it (device and inode), with the size and modification time it had when looked at.
public struct FileIdentity: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let seconds: Int
  let nanoseconds: Int
  init(_ info: stat) {
    device = info.st_dev; inode = info.st_ino; size = info.st_size
    seconds = info.st_mtimespec.tv_sec; nanoseconds = info.st_mtimespec.tv_nsec
  }
  /// The item at `url` now, without following a final symbolic link; nil only when there is none. A look-up that
  /// fails for any other reason throws, so it is never taken for absence.
  public static func at(_ url: URL) throws -> FileIdentity? {
    var info = stat()
    let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return EINVAL }
      return lstat(path, &info) == 0 ? 0 : errno
    }
    if code == ENOENT { return nil }
    guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path]) }
    return FileIdentity(info)
  }
}

/// A file the exporter published. It stays open, so it can be told apart from any file put at its name later.
public final class PublishedFile {
  public let url: URL
  private let descriptor: Int32
  private let published: FileIdentity?
  init(url: URL, descriptor: Int32) {
    self.url = url; self.descriptor = descriptor
    var info = stat()
    published = fstat(descriptor, &info) == 0 ? FileIdentity(info) : nil
  }
  deinit { close(descriptor) }
  /// True when `item` is this file, unchanged since it was published. The inode is taken from the descriptor now,
  /// because FAT and exFAT give an empty file a new number when it is renamed.
  func isPublished(_ item: FileIdentity) -> Bool {
    var info = stat()
    guard let published, fstat(descriptor, &info) == 0 else { return false }
    let now = FileIdentity(info)
    return item.device == now.device && item.inode == now.inode && item.size == published.size
      && item.seconds == published.seconds && item.nanoseconds == published.nanoseconds
  }
}

/// A name the save panel returned, and what the person agreed to there.
public struct ExportDestination: Sendable {
  public let url: URL
  let replacing: ExactCopyExporter.Replacement
  /// Looks at the name at once, so make this as soon as the panel returns. The panel asks before replacing an
  /// existing file, so the file there now is the one the person agreed to replace, and only that file will be.
  /// A file created between the person's click and this look cannot be told apart from one they agreed to replace.
  public init(chosen url: URL) {
    self.url = url
    // A look that fails agrees to nothing: the export then only creates, and reports anything it finds there.
    replacing = (try? FileIdentity.at(url)).map { .file($0) } ?? .nothing
  }
}

public enum ExactCopyExporter {
  /// What publishing may do to an item already at the destination.
  public enum Replacement: Sendable {
    /// Nothing may be there: an item that appears there is a collision.
    case nothing
    /// Only this file may be replaced: any other item there is a collision. If it is gone and nothing has taken its
    /// place, the copy is created as for `nothing`.
    case file(FileIdentity)
    /// Whatever is there is replaced, for a caller that has just checked it.
    case anything
  }

  /// Copies to a temporary file beside `destination`, publishes it as `replacing` allows and returns it.
  @discardableResult
  public static func export(source: URL, destination: URL, fileManager: FileManager = .default,
                            replacing: Replacement = .anything) throws -> PublishedFile
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
      switch replacing {
      case .nothing:
        return try publishExclusively(temporaryURL, at: destination)
      case .file(let agreed):
        guard let current = try FileIdentity.at(destination) else { return try publishExclusively(temporaryURL, at: destination) }
        guard current == agreed else { throw failure(EEXIST, destination) }
        // Checked immediately before: a file put there in the moment between is replaced, as no narrower check exists.
        return try replace(destination, with: temporaryURL, fileManager: fileManager)
      case .anything:
        if fileManager.fileExists(atPath: destination.path) { return try replace(destination, with: temporaryURL, fileManager: fileManager) }
        let file = try descriptor(temporaryURL, O_RDONLY | O_NOFOLLOW)
        do { try fileManager.moveItem(at: temporaryURL, to: destination) } catch { close(file); throw error }
        return PublishedFile(url: destination, descriptor: file)
      }
    } catch {
      do { try fileManager.removeItem(at: temporaryURL) }
      catch let cleanup as CocoaError where cleanup.code == .fileNoSuchFile {}
      catch { throw failure(error, leaving: [temporaryURL.path]) }
      throw error
    }
  }

  /// Opened before it is moved, so the published file is known by its descriptor rather than by its name.
  private static func replace(_ destination: URL, with temporary: URL, fileManager: FileManager) throws -> PublishedFile {
    let file = try descriptor(temporary, O_RDONLY | O_NOFOLLOW)
    do { _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [.usingNewMetadataOnly]) }
    catch { close(file); throw error }
    return PublishedFile(url: destination, descriptor: file)
  }

  /// Renames only if the name is free. A volume that cannot rename exclusively gets a hard link instead, and one
  /// with neither an exclusive create; each fails when the name is taken, so an existing item is never touched.
  private static func publishExclusively(_ temporary: URL, at destination: URL) throws -> PublishedFile {
    let file = try descriptor(temporary, O_RDONLY | O_NOFOLLOW)
    let renamed = call(temporary, destination) { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
    if renamed == 0 { return PublishedFile(url: destination, descriptor: file) }
    let linked = renamed == ENOTSUP ? call(temporary, destination) { link($0, $1) } : renamed
    if linked == 0 {
      let published = PublishedFile(url: destination, descriptor: file)
      try removeTemporary(temporary, of: published)
      return published
    }
    close(file)
    // FAT and exFAT, for example, support neither; the name is then claimed by an exclusive create.
    if linked == ENOTSUP { return try copyExclusively(temporary, to: destination) }
    throw failure(linked, destination)
  }

  /// Removes the temporary name of a file just published. If that fails, the publication is taken back and the
  /// error names whatever is left, so nothing stays behind unreported.
  private static func removeTemporary(_ temporary: URL, of published: PublishedFile) throws {
    let code = call(temporary) { unlink($0) }
    guard code != 0 else { return }
    throw failure(failure(code, temporary), leaving: [remove(published), temporary.path].compactMap { $0 })
  }

  /// Creates `destination` only if the name is free, copies `temporary` into it and removes `temporary`. This is for
  /// volumes with neither exclusive rename nor hard links, which leave no way to avoid the new file being visible,
  /// partly written, while its bytes are copied in. If the copy fails, the file is removed only while its name still
  /// holds it. Tests pass `copy` to fail the copy and `checked` to act once the name has been checked.
  static func copyExclusively(_ temporary: URL, to destination: URL,
                              copy: (Int32, Int32) -> Int32 = { fcopyfile($0, $1, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 ? 0 : errno },
                              checked: () -> Void = {}) throws -> PublishedFile {
    let source = try descriptor(temporary, O_RDONLY | O_NOFOLLOW)
    defer { close(source) }
    let target = try descriptor(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    let code = copy(source, target)
    let published = PublishedFile(url: destination, descriptor: target)
    guard code == 0 else { throw failure(failure(code, destination), leaving: [remove(published, checked: checked)].compactMap { $0 }) }
    try removeTemporary(temporary, of: published)
    return published
  }

  /// Removes a published file while its name still holds it and returns nil; otherwise leaves what is there and
  /// returns its path. Whatever is at the name is first moved to a private name, so the check and the removal see
  /// the same file. Another writer's file is put back with an exclusive rename or link; on a volume with neither it
  /// stays at the private name, and that path is returned.
  static func remove(_ published: PublishedFile, checked: () -> Void = {}) -> String? {
    let url = published.url
    let current: FileIdentity?
    do { current = try FileIdentity.at(url) } catch { return url.path }
    guard let current else { return nil }
    guard published.isPublished(current) else { return url.path }
    checked()
    let aside = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).frame-export-\(UUID().uuidString)")
    let moved = call(url, aside) { rename($0, $1) }
    guard moved == 0 else { return moved == ENOENT ? nil : url.path }
    if let item = try? FileIdentity.at(aside), published.isPublished(item) { return call(aside) { unlink($0) } == 0 ? nil : aside.path }
    if call(aside, url, { renamex_np($0, $1, UInt32(RENAME_EXCL)) }) == 0 { return url.path }
    if call(aside, url, { link($0, $1) }) == 0 { return call(aside) { unlink($0) } == 0 ? url.path : aside.path }
    return aside.path
  }

  private static func descriptor(_ url: URL, _ flags: Int32, _ mode: mode_t = 0) throws -> Int32 {
    var file: Int32 = -1
    let code = call(url) { path in file = open(path, flags, mode); return file >= 0 ? 0 : -1 }
    guard code == 0 else { throw failure(code, url) }
    return file
  }
  /// Runs a system call on file-system paths and returns 0 or the error number.
  private static func call(_ url: URL, _ body: (UnsafePointer<CChar>) -> Int32) -> Int32 {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return EINVAL }
      return body(path) == 0 ? 0 : errno
    }
  }
  private static func call(_ from: URL, _ to: URL, _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32) -> Int32 {
    from.withUnsafeFileSystemRepresentation { from in
      to.withUnsafeFileSystemRepresentation { to in
        guard let from, let to else { return EINVAL }
        return body(from, to) == 0 ? 0 : errno
      }
    }
  }
  /// `reason`, naming every path a clean-up could not remove.
  private static func failure(_ reason: Error, leaving paths: [String]) -> Error {
    paths.isEmpty ? reason : AssetError(reason.localizedDescription + " Left as it is: " + paths.joined(separator: ", ") + ".")
  }
  private static func failure(_ code: Int32, _ url: URL) -> Error {
    let info: [String: Any] = [NSFilePathErrorKey: url.path, NSURLErrorKey: url]
    return code == EEXIST ? CocoaError(.fileWriteFileExists, userInfo: info) : NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: info)
  }
}
