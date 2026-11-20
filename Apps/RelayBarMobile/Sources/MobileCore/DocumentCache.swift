import Composition
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The index contains only stamps and filenames. Each replacement payload has its own name,
/// so a reader holding the old mapped bytes can finish after replacement or eviction.
package actor DocumentCache {
  package static let thumbnailSourceLimit = 20 << 20
  private struct Record: Codable {
    var profile: UUID
    var stamp: FileStamp
    var date: Date
    var accessed: Date
    var bytes: Int
    var name: UUID
  }
  private var allowedPictures: Set<String> = []
  func keepWebsitePictures(_ keys: Set<CacheIdentity>) throws {
    allowedPictures = try Set(keys.map { try id($0) + "-website" })
    let next = records.filter { !$0.key.hasSuffix("-website") || allowedPictures.contains($0.key) }
    if next.count != records.count { try commit(next) }
  }

  package func websitePicture(_ key: CacheIdentity) throws -> Data? {
    let identifier = try id(key) + "-website"
    return allowedPictures.contains(identifier) ? hit(identifier)?.data : nil
  }

  package func saveWebsitePicture(_ bytes: Data, key: CacheIdentity) throws {
    let identifier = try id(key) + "-website"
    guard allowedPictures.contains(identifier) else { return }
    try store(
      .init(stamp: .init(size: UInt64(bytes.count), directory: false), data: bytes, date: Date()),
      key: identifier, profile: key.profile)
  }
  private var previewSlots = 4
  private var previewWaiters: [(id: UUID, ready: CheckedContinuation<Bool, Never>)] = []
  private var thumbnailSlots = 2
  private var thumbnailWaiters: [CheckedContinuation<Void, Never>] = []
  private var records: [String: Record] = [:]
  private var generations: [UUID: UInt64] = [:]
  private let directory: URL
  private let budget: Int
  private var index: URL { directory.appending(path: "index.json") }

  package init(directory: URL, budget: Int = 256 << 20) {
    self.directory = directory.appending(path: "v2")
    self.budget = max(0, budget)
    if let data = try? Data(contentsOf: self.directory.appending(path: "index.json")),
      let saved = try? JSONDecoder().decode([String: Record].self, from: data)
    {
      records = saved
    }
    let live = Set(records.values.map { $0.name.uuidString })
    for url
      in (try? FileManager.default.contentsOfDirectory(
        at: self.directory, includingPropertiesForKeys: nil)) ?? []
    where UUID(uuidString: url.lastPathComponent) != nil && !live.contains(url.lastPathComponent) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func id(_ key: CacheIdentity) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
  }

  private func commit(_ next: [String: Record]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(next).write(to: index, options: .atomic)
    for (key, old) in records where next[key]?.name != old.name {
      try? FileManager.default.removeItem(at: directory.appending(path: old.name.uuidString))
    }
    records = next
  }

  package func size(_ profile: UUID) -> Int {
    let current = records.values.filter { $0.profile == profile }.reduce(0) { $0 + $1.bytes }
    let legacy = directory.deletingLastPathComponent().appending(path: profile.uuidString)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: legacy,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
    return files.reduce(current) { size, file in
      let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      return size + (info?.isRegularFile == true ? info?.fileSize ?? 0 : 0)
    }
  }

  package func clear(_ profile: UUID) throws {
    generations[profile, default: 0] &+= 1
    try commit(records.filter { $0.value.profile != profile })
    // First-version property-list cache.
    let legacy = directory.deletingLastPathComponent().appending(path: profile.uuidString)
    if FileManager.default.fileExists(atPath: legacy.path) {
      try FileManager.default.removeItem(at: legacy)
    }
  }

  private func hit(_ key: String, matching stamp: FileStamp? = nil) -> CachedFile? {
    guard var record = records[key], stamp == nil || record.stamp == stamp,
      let data = try? Data(
        contentsOf: directory.appending(path: record.name.uuidString), options: .alwaysMapped),
      data.count == record.bytes
    else { return nil }
    record.accessed = Date()
    records[key] = record
    try? JSONEncoder().encode(records).write(to: index, options: .atomic)
    return CachedFile(stamp: record.stamp, data: data, date: record.date)
  }

  func cached(_ key: CacheIdentity) async -> CachedFile? {
    guard let identifier = try? id(key) else { return nil }
    if let file = hit(identifier) { return file }
    // The first mobile cache combined metadata and bytes in a binary property list.
    let legacy = directory.deletingLastPathComponent().appending(path: key.profile.uuidString)
      .appending(path: identifier)
    guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
    let generation = generations[key.profile, default: 0]
    let file = await Task.detached {
      try? PropertyListDecoder().decode(
        CachedFile.self, from: Data(contentsOf: legacy, options: .mappedIfSafe))
    }.value
    guard generation == generations[key.profile, default: 0], let file else { return nil }
    if let newer = hit(identifier) { return newer }
    do {
      try store(file, key: identifier, profile: key.profile)
      try FileManager.default.removeItem(at: legacy)
    } catch { return file }
    return file
  }

  private func store(_ file: CachedFile, key: String, profile: UUID) throws {
    guard file.data.count <= budget else {
      if records[key] != nil { try commit(records.filter { $0.key != key }) }
      return
    }
    let name = UUID()
    let url = directory.appending(path: name.uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try file.data.write(to: url, options: .atomic)
    var next = records
    next[key] = Record(
      profile: profile, stamp: file.stamp, date: file.date, accessed: Date(),
      bytes: file.data.count, name: name)
    var size = next.values.reduce(0) { $0 + $1.bytes }
    for entry in next.sorted(by: { $0.value.accessed < $1.value.accessed }) {
      guard size > budget else { break }
      size -= entry.value.bytes
      next.removeValue(forKey: entry.key)
    }
    do { try commit(next) } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  func load(_ key: CacheIdentity, files: any RemoteFiles, limit: Int) async throws -> CachedFile {
    let generation = generations[key.profile, default: 0]
    let stamp = try await files.stat(key.path)
    guard !stamp.directory, stamp.size ?? 0 <= UInt64(limit) else {
      throw CompositionError("File exceeds the reading limit.")
    }
    let identifier = try id(key)
    if stamp.modified != nil, stamp.size != nil, let previous = hit(identifier, matching: stamp) {
      return previous
    }
    let data = try await files.read(key.path, limit: limit)
    guard data.count <= limit, try await files.stat(key.path) == stamp,
      stamp.size.map({ $0 == data.count }) ?? true
    else { throw CompositionError("The file changed while it was being read. Open it again.") }
    try Task.checkCancellation()
    let file = CachedFile(stamp: stamp, data: data, date: Date())
    // Caching is best effort: a full disk must not stop a document that has arrived from opening.
    if generation == generations[key.profile, default: 0] {
      try? store(file, key: identifier, profile: key.profile)
    }
    return file
  }

  private func cancelPreview(_ id: UUID) {
    guard let i = previewWaiters.firstIndex(where: { $0.id == id }) else { return }
    previewWaiters.remove(at: i).ready.resume(returning: false)
  }
  func preview(_ key: CacheIdentity, stamp: FileStamp, files: any RemoteFiles, saver: Bool)
    async throws -> DocumentPreview?
  {
    guard !saver, let ranged = files as? any RangeFiles else { return nil }
    let generation = generations[key.profile, default: 0]
    let identifier = try id(key) + "-preview"
    if previewSlots > 0 {
      previewSlots -= 1
    } else {
      let id = UUID()
      let admitted = await withTaskCancellationHandler {
        await withCheckedContinuation { previewWaiters.append((id, $0)) }
      } onCancel: {
        Task { await self.cancelPreview(id) }
      }
      guard admitted else { throw CancellationError() }
    }
    defer {
      if previewWaiters.isEmpty {
        previewSlots += 1
      } else {
        previewWaiters.removeFirst().ready.resume(returning: true)
      }
    }
    try Task.checkCancellation()
    if stamp.modified != nil, let cached = hit(identifier, matching: stamp) {
      return try JSONDecoder().decode(DocumentPreview.self, from: cached.data)
    }
    let bytes = try await ranged.bytes(
      key.path, range: 0..<min(4096, stamp.size ?? 4096), interactive: false)
    try Task.checkCancellation()
    guard generation == generations[key.profile, default: 0], !bytes.contains(0) else { return nil }
    let preview = DocumentPreview(String(decoding: bytes.prefix(4096), as: UTF8.self))
    if stamp.modified != nil {
      guard try await files.stat(key.path) == stamp else { return nil }
      try Task.checkCancellation()
      if generation == generations[key.profile, default: 0] {
        try? store(
          .init(stamp: stamp, data: JSONEncoder().encode(preview), date: Date()), key: identifier,
          profile: key.profile)
      }
    }
    return preview
  }

  package func thumbnail(_ key: CacheIdentity, files: any RemoteFiles, stamp: FileStamp, limit: Int)
    async throws -> Data?
  {
    let limit = min(limit, Self.thumbnailSourceLimit)
    guard limit > 0, let size = stamp.size, size <= limit else { return nil }
    let identifier = try id(key) + "-thumbnail"
    let generation = generations[key.profile, default: 0]
    if stamp.modified != nil, let cached = hit(identifier, matching: stamp) { return cached.data }
    if thumbnailSlots > 0 {
      thumbnailSlots -= 1
    } else {
      await withCheckedContinuation { thumbnailWaiters.append($0) }
    }
    defer {
      if thumbnailWaiters.isEmpty {
        thumbnailSlots += 1
      } else {
        thumbnailWaiters.removeFirst().resume()
      }
    }
    try Task.checkCancellation()
    let original: Data
    if let ranged = files as? any RangeFiles {
      original = try await ranged.bytes(key.path, range: 0..<size, interactive: false)
    } else {
      original = try await files.read(key.path, limit: limit)
    }
    guard original.count == size, try await files.stat(key.path) == stamp else { return nil }
    try Task.checkCancellation()
    let data = await Task.detached { () -> Data? in
      guard let source = CGImageSourceCreateWithData(original as CFData, nil),
        let small = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
          ] as CFDictionary)
      else { return nil }
      let bytes = NSMutableData()
      guard
        let output = CGImageDestinationCreateWithData(
          bytes, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(output, small, nil)
      return CGImageDestinationFinalize(output) ? bytes as Data : nil
    }.value
    if let data, generation == generations[key.profile, default: 0] {
      try? store(
        .init(stamp: stamp, data: data, date: Date()), key: identifier, profile: key.profile)
    }
    return data
  }
}
