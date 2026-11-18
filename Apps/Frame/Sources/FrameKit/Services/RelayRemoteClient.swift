import BridgeProtocol
import AssetGrouping
import Combine
import CryptoKit
import Foundation

public struct RemoteAssetReference: Hashable, Sendable {
  public let source: BridgeSource
  public let listingID: UUID
  public let entry: BridgeEntry
  public let companions: [BridgeEntry]
  public var sidecar: BridgeEntry? { companions.first { ($0.name as NSString).pathExtension.lowercased() == "json" } }
  public var archiveRoot: String? = nil
  public var recordID: UUID? = nil
  /// For an archived asset, where each member was before it was archived, in member order. Opened times are
  /// tracked under these paths; remote operations use the members' stored paths.
  public var originals: [String] = []
  public init(source: BridgeSource, listingID: UUID, entry: BridgeEntry,
              companions: [BridgeEntry] = [], archiveRoot: String? = nil, recordID: UUID? = nil) {
    self.source = source; self.listingID = listingID; self.entry = entry
    self.companions = companions
    self.archiveRoot = archiveRoot; self.recordID = recordID
  }
}

@MainActor public final class RemoteTransferState: ObservableObject {
  public init() {}
  @Published public var messages: [String: String] = [:]
}

private actor RemoteReadSlots {
  private let limit: Int
  private var active = 0
  private var queue: [(Int, CheckedContinuation<Void, Never>)] = []
  init(limit: Int = 2) { self.limit = limit }
  func acquire(priority: Int) async {
    if active < limit { active += 1; return }
    await withCheckedContinuation { continuation in
      let index = queue.firstIndex { $0.0 > priority } ?? queue.count
      queue.insert((priority, continuation), at: index)
    }
  }
  func release() { if queue.isEmpty { active -= 1 } else { queue.removeFirst().1.resume() } }
}

public actor RelayRemoteClient: RemoteAssetServing {
  /// Starts the text given in place of a companion that could not be read; the reason follows.
  public static let unreadableCompanionPrefix = "Cannot preview: "
  /// The text given in place of a companion larger than a preview reads.
  public static let oversizedCompanionText = "Preview exceeds 2 MiB."
  private let progress: @Sendable (String, String?) -> Void
  public typealias Transport = @Sendable (BridgeRequest) async throws -> BridgeResponse
  private let transport: Transport
  private let sessionFailure: @Sendable (BridgeError) async -> Void
  private var stopped = false
  private var shutdownTask: Task<Void, Never>?
  private var draining: [UUID: Task<Void, Never>] = [:]
  private var releases: [UUID: Task<Void, Never>] = [:]
  private let slots = RemoteReadSlots()
  private let listingSlots = RemoteReadSlots(limit: 1)
  private var latestListings: [String: (ScanResult, Date)] = [:]
  private struct Renewal { let id: UUID; let task: Task<ScanResult, Error>; var consumers: Set<UUID> }
  private var renewals: [String: Renewal] = [:]
  private var cache: [String: (AssetFile, Date)] = [:]
  private let cacheRoot: URL
  private let sharedRoot: @Sendable () throws -> URL
  private let cacheLimit: Int64 = 512 * 1_024 * 1_024
  private var pinnedPrefix: String?
  private struct Flight { let task: Task<AssetFile, Error>; var consumers: Set<UUID> }
  private var flights: [String: Flight] = [:]
  private let previews: RemotePreviewCache
  private struct PreviewFlight { let task: Task<BridgeAssetResult, Error>; var consumers: Set<UUID> }
  private var previewFlights: [String: PreviewFlight] = [:]
  private var validatedPreviews: [String: String] = [:]

  public init(transport: @escaping Transport, cacheRoot: URL? = nil,
              sharedRoot: @escaping @Sendable () throws -> URL = { try FrameBridgeEnvironment.root() },
              previewCache: RemotePreviewCache = RemotePreviewCache(),
              progress: @escaping @Sendable (String, String?) -> Void = { _, _ in },
              sessionFailure: @escaping @Sendable (BridgeError) async -> Void = { _ in }) {
    self.progress = progress
    self.transport = transport
    self.sessionFailure = sessionFailure
    self.sharedRoot = sharedRoot
    self.previews = previewCache
    self.cacheRoot = cacheRoot ?? RemoteSessionStorage.root.appendingPathComponent("Originals-\(UUID())")
  }
  public func pin(_ photo: PhotoItem?) {
    guard !stopped else { return }
    pinnedPrefix = photo.flatMap { photo in photo.remote.map { "\(photo.id)|\($0.listingID)|" } }
  }
  public func catalog() async throws -> BridgeResponse {
    let response = try await send(BridgeRequest("catalog"))
    if let error = response.error { throw BridgeError(error) }
    guard (response.sources ?? []).allSatisfy(FrameBridgeEnvironment.validSource),
          (response.locations ?? []).allSatisfy({ FrameBridgeEnvironment.validSource($0.source) && FrameBridgeEnvironment.validPath($0.path) }) else {
      throw BridgeError("Invalid remote location catalog.")
    }
    return response
  }
  public func handoff(_ nonce: UUID) async throws -> BridgeHandoff {
    var request = BridgeRequest("handoff"); request.nonce = nonce
    guard let handoff = try await send(request).handoff else { throw BridgeError("This handoff is unavailable.") }
    guard FrameBridgeEnvironment.validSource(handoff.source), FrameBridgeEnvironment.validPath(handoff.path), handoff.focus.count <= 1_000,
          handoff.focus.allSatisfy(FrameBridgeEnvironment.validName) else { throw BridgeError("Invalid viewer handoff.") }
    return handoff
  }
  public func list(source: BridgeSource, path: String) async throws -> ScanResult {
    guard FrameBridgeEnvironment.validSource(source), FrameBridgeEnvironment.validPath(path) else { throw BridgeError("Choose a saved host and enter an absolute remote folder path.") }
    await listingSlots.acquire(priority: 0)
    do {
      try Task.checkCancellation()
      let result = try await listDirectory(source: source, path: path)
      latestListings[source.id + "|" + path] = (result, .now)
      var retainedAssets = latestListings.values.reduce(0) { $0 + $1.0.files.count }
      for key in latestListings.keys.sorted(by: { latestListings[$0]!.1 < latestListings[$1]!.1 })
        where key != source.id + "|" + path && (latestListings.count > 32 || retainedAssets > 20_000) {
        if let removed = latestListings.removeValue(forKey: key) { retainedAssets -= removed.0.files.count }
      }
      await listingSlots.release()
      return result
    } catch { await listingSlots.release(); throw error }
  }
  /// Call only after an explicitly chosen folder has opened successfully, including cache hits.
  /// Directory expansion, scanning, refresh and capability renewal never call this operation.
  public func rememberOpen(source: BridgeSource, path: String) async throws {
    guard FrameBridgeEnvironment.validSource(source), FrameBridgeEnvironment.validPath(path) else {
      throw BridgeError("Choose a saved host and enter an absolute remote folder path.")
    }
    try Task.checkCancellation()
    var request = BridgeRequest("rememberOpen"); request.sourceID = source.id; request.path = path
    let response = try await send(request)
    if let error = response.error { throw BridgeError(error) }
  }
  private func listDirectory(source: BridgeSource, path: String) async throws -> ScanResult {
    var request = BridgeRequest("list"); request.sourceID = source.id; request.path = path
    let response = try await operation(request)
    defer { release(response.jobID) }
    guard let listingID = response.listingID, let entries = response.entries, entries.count <= 10_000 else {
      throw BridgeError("Invalid remote folder response.")
    }
    let prefix = path == "/" ? "/" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let expectedParent = path == "/" ? "/" : "/" + prefix
    guard Set(entries.map(\.name)).count == entries.count,
          entries.allSatisfy({ FrameBridgeEnvironment.validName($0.name) && $0.size >= 0
            && $0.path == (expectedParent == "/" ? "/" : expectedParent + "/") + $0.name }) else {
      throw BridgeError("The remote listing contains invalid or ambiguous paths.")
    }
    let rootID = Self.rootID(source.id)
    let files = entries.filter { !$0.directory }
    let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    var photos = files.compactMap { entry -> PhotoItem? in
      guard let format = PhotoFormat(pathExtension: (entry.name as NSString).pathExtension) else { return nil }
      return PhotoItem(id: FavoriteRecord.makeKey(rootID: rootID, relativePath: entry.path), rootID: rootID,
        url: Self.remoteURL(source: source.id, path: entry.path), relativePath: entry.path,
        folderRelativePath: expectedParent, name: entry.name, format: format, fileSize: entry.size,
        createdAt: nil, modifiedAt: nil, fileIdentifier: nil)
    }
    let companions = files.filter { !AssetCompanionNames.isMedia($0.name) }.map {
      AssetFile(url: Self.remoteURL(source: source.id, path: $0.path), relativePath: $0.path,
                size: $0.size, modifiedAt: nil, identifier: nil)
    }
    photos = AssetPairing.pair(photos, sidecars: companions).map { photo in
      var photo = photo
      photo.remote = RemoteAssetReference(source: source, listingID: listingID,
        entry: filesByPath[photo.relativePath]!,
        companions: photo.companions.compactMap { filesByPath[$0.relativePath] })
      return photo
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let folders = entries.filter(\.directory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .map { FolderNode(id: $0.path, name: $0.name, relativePath: $0.path, photoCount: 0, children: []) }
    let extraFiles = companions.filter { !AssetCompanionNames.isPrimary($0.relativePath) }
    let allFiles = FileScanner.allFiles(photos: photos, extras: extraFiles, rootID: rootID).map { item in
      var item = item
      if item.remote == nil, let entry = filesByPath[item.relativePath] {
        item.remote = RemoteAssetReference(source: source, listingID: listingID, entry: entry)
      }
      return item
    }
    return ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: path == "/" ? "/" : (path as NSString).lastPathComponent,
      relativePath: path, photoCount: photos.count, children: folders), files: allFiles)
  }
  public static func rootID(_ sourceID: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data(sourceID.utf8)).prefix(16))
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }
  public func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry] {
    guard paths.count <= 128, paths.allSatisfy({ FrameBridgeEnvironment.validPath($0) && $0.hasPrefix(root == "/" ? "/" : root + "/") }) else {
      throw BridgeError("Document resource limit exceeded.")
    }
    var request = BridgeRequest("documentStat")
    request.sourceID = source.id; request.root = root; request.paths = paths
    let response = try await operation(request)
    defer { release(response.jobID) }
    let entries = response.asset?.entries ?? []
    // At most one entry for each path asked about; callers key the reply by path.
    guard Set(entries.map(\.path)).count == entries.count,
          entries.allSatisfy({ paths.contains($0.path) && !$0.directory }) else { throw BridgeError("Invalid resource response.") }
    return entries
  }
  private static func remoteURL(source: String, path: String) -> URL {
    var value = URLComponents(); value.scheme = "frame-remote"; value.host = source; value.path = path
    return value.url!
  }
  private func key(_ photo: PhotoItem, _ entry: BridgeEntry) -> String {
    "\(photo.id)|\(photo.format.isDocument ? entry.fingerprint ?? entry.modified : photo.remote!.listingID.uuidString)|\(entry.path)"
  }
  public func cachedMedia(_ photo: PhotoItem) -> PhotoItem? {
    guard !stopped, let remote = photo.remote, let value = cache[key(photo, remote.entry)],
          (try? value.0.validate()) != nil else { return nil }
    return localPhoto(photo, media: value.0, companions: [])
  }
  public func resolve(_ photo: PhotoItem, includeCompanions: Bool = false, allowVideo: Bool = false, priority: Int = 0) async throws -> PhotoItem {
    guard let remote = photo.remote else { return photo }
    if photo.format.isVideo && !allowVideo {
      if let cached = cachedMedia(photo) { return cached }
      throw BridgeError("Open this video to download it for playback (up to 100 MiB).")
    }
    let media = try await read(photo, entry: remote.entry, priority: priority)
    var companions: [AssetFile] = []
    if includeCompanions {
      for entry in remote.companions { companions.append(try await read(photo, entry: entry, priority: priority)) }
    }
    return localPhoto(photo, media: media, companions: companions)
  }
  public func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText] {
    var result: [BridgeCompanionText] = [], remaining = 256_000
    for entry in photo.remote?.companions ?? [] {
      guard remaining > 0 else { break }
      let text: String
      if entry.size > SidecarReader.maximumBytes { text = Self.oversizedCompanionText }
      else {
        do {
          let file = try await read(photo, entry: entry, priority: 0)
          text = await Task.detached { SidecarReader.read(file) }.value
        } catch { text = Self.unreadableCompanionPrefix + error.localizedDescription }
      }
      result.append(BridgeCompanionText(name: entry.name, text: String(text.prefix(remaining))))
      remaining -= text.count
    }
    return result
  }
  private func localPhoto(_ photo: PhotoItem, media: AssetFile, companions: [AssetFile]) -> PhotoItem {
    // This resolved value is for decoding or a specifically requested export only.
    // The store retains the remote original, never this cache-backed value.
    PhotoItem(id: photo.id, rootID: photo.rootID, url: media.url, relativePath: photo.relativePath,
      folderRelativePath: photo.folderRelativePath, name: photo.name, format: photo.format,
      fileSize: media.size, createdAt: nil, modifiedAt: media.modifiedAt, fileIdentifier: media.identifier, companions: companions)
  }
  private func read(_ photo: PhotoItem, entry: BridgeEntry, priority: Int) async throws -> AssetFile {
    let cacheKey = key(photo, entry)
    if let value = cache[cacheKey], (try? value.0.validate()) != nil { cache[cacheKey]?.1 = .now; return value.0 }
    let consumer = UUID()
    let task: Task<AssetFile, Error>
    if let existing = flights[cacheKey] {
      task = existing.task; flights[cacheKey]?.consumers.insert(consumer)
    } else {
      task = Task { try await transfer(photo, entry: entry, priority: priority) }
      flights[cacheKey] = Flight(task: task, consumers: [consumer])
    }
    return try await withTaskCancellationHandler {
      do {
        let result = try await task.value
        releaseFlight(cacheKey, consumer: consumer)
        try Task.checkCancellation()
        return result
      } catch { releaseFlight(cacheKey, consumer: consumer); throw error }
    } onCancel: { Task { await self.releaseFlight(cacheKey, consumer: consumer) } }
  }
  private func releaseFlight(_ key: String, consumer: UUID) {
    guard flights[key]?.consumers.remove(consumer) != nil else { return }
    if flights[key]?.consumers.isEmpty == true, let task = flights.removeValue(forKey: key)?.task { retire(task) }
  }
  private func transfer(_ photo: PhotoItem, entry: BridgeEntry, priority: Int) async throws -> AssetFile {
    let key = key(photo, entry)
    if let value = cache[key], (try? value.0.validate()) != nil { cache[key]?.1 = .now; return value.0 }
    let limit: Int64 = 100 * 1_024 * 1_024
    guard entry.size <= limit else { throw BridgeError("\(entry.name) exceeds the remote viewer limit. Download it in RelayBar instead.") }
    await slots.acquire(priority: priority)
    do {
      try Task.checkCancellation()
      if let value = cache[key], (try? value.0.validate()) != nil { await slots.release(); return value.0 }
      let response = try await fetch(photo, entry: entry)
      defer { release(response.jobID) }
      // Components at "/" bytes, as the file system splits them; a name may start with a combining mark.
      guard let path = response.cacheRelativePath, let job = response.jobID,
            let parts = try? DocumentResources.components(path), parts.count == 3, parts[1] == job.uuidString,
            path.hasPrefix("FrameTransfers-"), parts[2] == entry.name else {
        throw BridgeError("Invalid remote cache response.")
      }
      let sharedFile = try AssetPaths.below(sharedRoot(), relativePath: path)
      let snapshot = try AssetFile.snapshot(sharedFile, relativePath: entry.path)
      guard snapshot.size == entry.size, snapshot.size <= limit else { throw BridgeError("The remote file changed. Refresh and retry.") }
      try Task.checkCancellation()
      trimCache(incoming: entry.size)
      let directory = cacheRoot.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let localURL = directory.appendingPathComponent(entry.name)
      do { try FileManager.default.copyItem(at: sharedFile, to: localURL) }
      catch { try? FileManager.default.removeItem(at: directory); throw error }
      let file: AssetFile
      do { file = try AssetFile.snapshot(localURL, relativePath: entry.path) }
      catch { try? FileManager.default.removeItem(at: directory); throw error }
      cache[key] = (file, .now)
      await slots.release()
      return file
    } catch { await slots.release(); throw error }
  }
  /// The broker retains 32 listings for one hour. Renew a stale capability on demand,
  /// and refuse changed media/JSON instead of downloading a different snapshot silently.
  private func fetch(_ photo: PhotoItem, entry: BridgeEntry, operation name: String = "fetch",
                     pixels: Int? = nil, fingerprint: String? = nil) async throws -> BridgeResponse {
    guard let remote = photo.remote else { throw BridgeError("Remote asset unavailable.") }
    let path = (entry.path as NSString).deletingLastPathComponent
    let key = remote.source.id + "|" + path
    func listingID(in result: ScanResult) throws -> UUID {
      guard let current = result.files.first(where: { $0.remote?.entry.path == remote.entry.path })?.remote,
            (entry == current.entry || current.companions.contains(entry)) else {
        throw BridgeError("The remote file changed. Refresh the folder before downloading.")
      }
      return current.listingID
    }
    var request = BridgeRequest(name)
    request.listingID = try latestListings[key].map { try listingID(in: $0.0) } ?? remote.listingID
    request.name = entry.name
    request.path = entry.path; request.pixels = pixels; request.fingerprint = fingerprint
    do { return try await operation(request, photoID: photo.id) }
    catch let error as BridgeError where error.message == "Refresh this remote folder before downloading." {
      try Task.checkCancellation()
      let result = try await renew(source: remote.source, path: path, key: key)
      try Task.checkCancellation()
      request.listingID = try listingID(in: result)
      return try await operation(request, photoID: photo.id)
    }
  }
  public func preview(_ photo: PhotoItem, pixels: Int, priority: Int = 0) async throws -> BridgeAssetResult {
    guard let remote = photo.remote else { throw BridgeError("Not a remote asset.") }
    let pixels = pixels <= 512 ? 512 : 2048
    let key = [remote.source.id, remote.entry.path, remote.companions.map(\.path).joined(separator: "|"), String(pixels), "v2"].joined(separator: "|")
    let validation = photo.metadataContentID + "|" + ([remote.entry] + remote.companions).map { $0.fingerprint ?? "" }.joined(separator: "|")
    if validatedPreviews[key] == validation, let result = await previews.read(key) { return result }
    let consumer = UUID()
    let flightKey = key + "|" + validation
    let task: Task<BridgeAssetResult, Error>
    if let flight = previewFlights[flightKey] {
      task = flight.task; previewFlights[flightKey]?.consumers.insert(consumer)
    } else {
      task = Task {
        await self.slots.acquire(priority: priority)
        do {
          try Task.checkCancellation()
          let cached = await self.previews.read(key)
          let response = try await self.fetch(photo, entry: remote.entry, operation: "preview",
            pixels: pixels, fingerprint: cached?.fingerprint)
          self.release(response.jobID)
          try Task.checkCancellation()
          guard let value = response.asset else { throw BridgeError("Invalid remote preview.") }
          let result: BridgeAssetResult
          if value.unchanged == true, let cached, value.fingerprint == cached.fingerprint { result = cached }
          else {
            guard let image = value.image, image.count <= 4 * 1_024 * 1_024, value.fingerprint != nil else {
              throw BridgeError("Remote preview unavailable.")
            }
            result = value
            try await self.previews.write(result, key: key)
          }
          self.validatedPreviews[key] = validation
          if self.validatedPreviews.count > 5_000 { self.validatedPreviews = [key: validation] }
          await self.slots.release()
          return result
        } catch { await self.slots.release(); throw error }
      }
      previewFlights[flightKey] = PreviewFlight(task: task, consumers: [consumer])
    }
    return try await withTaskCancellationHandler {
      do {
        let value = try await task.value
        finishPreview(flightKey, consumer: consumer)
        try Task.checkCancellation()
        return value
      } catch { finishPreview(flightKey, consumer: consumer); throw error }
    } onCancel: { Task { await self.finishPreview(flightKey, consumer: consumer) } }
  }
  private func finishPreview(_ key: String, consumer: UUID) {
    guard previewFlights[key]?.consumers.remove(consumer) != nil else { return }
    if previewFlights[key]?.consumers.isEmpty == true, let task = previewFlights.removeValue(forKey: key)?.task { retire(task) }
  }
  public func mutate(_ photo: PhotoItem, action: String, root: String) async throws -> UUID? {
    guard let remote = photo.remote else { throw BridgeError("Not a remote asset.") }
    var request = BridgeRequest(action)
    request.sourceID = remote.source.id; request.root = remote.archiveRoot ?? root
    request.listingID = remote.listingID; request.name = remote.entry.name; request.path = remote.entry.path
    request.recordID = remote.recordID
    let parent = (remote.entry.path as NSString).deletingLastPathComponent
    let listingKey = remote.source.id + "|" + parent
    func currentListing(_ result: ScanResult) throws -> UUID {
      guard let current = result.photos.first(where: { $0.remote?.entry.path == remote.entry.path })?.remote,
            current.entry == remote.entry, current.companions == remote.companions else {
        throw BridgeError("The remote asset changed. Refresh before changing it.")
      }
      return current.listingID
    }
    if action != "restore", let latest = latestListings[listingKey] { request.listingID = try currentListing(latest.0) }
    let response: BridgeResponse
    do { response = try await operation(request) }
    catch let error as BridgeError where error.message == "Refresh this remote folder before downloading." && action != "restore" {
      let latest = try await renew(source: remote.source, path: parent, key: listingKey)
      request.listingID = try currentListing(latest)
      response = try await operation(request)
    }
    defer { release(response.jobID) }
    validatedPreviews.removeAll()
    return response.asset?.recordID
  }
  public func delete(_ photos: [PhotoItem], root: String) async -> [FileActionFailure] {
    var failures: [FileActionFailure] = []
    var batches: [[PhotoItem]] = [], pending: [PhotoItem] = [], listings = Set<UUID>()
    for photo in photos {
      let listing = photo.remote?.listingID
      // Leave room in the broker's 32-listing cache for concurrent preview renewals.
      if pending.count == FrameBridgeEnvironment.maximumBatchAssets
        || (listings.count == 16 && listing.map { !listings.contains($0) } == true) {
        batches.append(pending); pending = []; listings = []
      }
      pending.append(photo)
      if let listing { listings.insert(listing) }
    }
    if !pending.isEmpty { batches.append(pending) }
    for chunk in batches {
      do {
        guard let source = chunk.first?.remote?.source,
              chunk.allSatisfy({ $0.remote?.source == source }) else { throw BridgeError("Choose assets from one remote host.") }
        let batchRoot = chunk.first?.remote?.archiveRoot ?? root
        func request(_ targets: [PhotoItem]) -> BridgeRequest {
          var request = BridgeRequest("deleteBatch"); request.sourceID = source.id; request.root = batchRoot
          request.targets = targets.compactMap { $0.remote.map { BridgeDeleteTarget(listingID: $0.listingID, path: $0.entry.path, recordID: $0.recordID) } }
          return request
        }
        let response: BridgeResponse
        do { response = try await operation(request(chunk)) }
        catch let error as BridgeError where error.message == "Refresh this remote folder before deleting." {
          // The broker rejected the entire request before starting; renew each expired directory once.
          var current: [PhotoItem] = []
          if chunk.first?.archiveID != nil { current = try await archivedAssets(source: source, root: batchRoot) }
          else {
            for path in Set(chunk.map(\.folderRelativePath)).sorted() {
              current += try await list(source: source, path: path).photos
            }
          }
          let byPath = Dictionary(uniqueKeysWithValues: current.compactMap { photo in photo.remote.map { ($0.entry.path, photo) } })
          let renewed = try chunk.map { photo -> PhotoItem in
            guard let remote = photo.remote, let newer = byPath[remote.entry.path],
                  newer.remote?.entry == remote.entry, newer.remote?.companions == remote.companions else {
              throw BridgeError("The remote asset changed. Refresh before deleting.")
            }
            return newer
          }
          response = try await operation(request(renewed))
        }
        defer { release(response.jobID) }
        guard let outcomes = response.asset?.outcomes, outcomes.count == chunk.count,
              Set(outcomes.map(\.path)) == Set(chunk.compactMap { $0.remote?.entry.path }) else {
          throw BridgeError("Deletion result unavailable. Refresh to check which files remain.")
        }
        let byPath = Dictionary(uniqueKeysWithValues: chunk.map { ($0.remote!.entry.path, $0) })
        for outcome in outcomes {
          if let error = outcome.error, let photo = byPath[outcome.path] {
            failures.append(FileActionFailure(photo: photo, reason: error))
          }
        }
      } catch { failures += chunk.map { FileActionFailure(photo: $0, reason: error.localizedDescription) } }
    }
    return failures
  }
  public func archivedAssets(source: BridgeSource, root: String) async throws -> [PhotoItem] {
    var request = BridgeRequest("collection"); request.sourceID = source.id; request.root = root
    let response = try await operation(request)
    defer { release(response.jobID) }
    guard let records = response.asset?.records, records.count <= 10_000, let listingID = response.listingID else {
      throw BridgeError("Invalid archive response.")
    }
    // A record's id is its item's id in the list, and Delete keys members by path: neither may repeat.
    let members = records.flatMap { $0.members.map(\.path) }
    guard Set(records.map(\.id)).count == records.count, Set(members).count == members.count else {
      throw BridgeError("Invalid archive response.")
    }
    return try records.map { record in
      guard let media = record.members.first, let original = record.originals.first,
            record.members.count == record.originals.count, record.members.count <= 10_000,
            record.originals.allSatisfy(FrameBridgeEnvironment.validPath),
            record.members.allSatisfy({ FrameBridgeEnvironment.validPath($0.path) && FrameBridgeEnvironment.validName($0.name) && $0.size >= 0 }),
            let format = PhotoFormat(pathExtension: (media.name as NSString).pathExtension) else { throw BridgeError("Invalid asset record.") }
      let rootID = Self.rootID(source.id)
      let companions = Array(record.members.dropFirst())
      var photo = PhotoItem(id: record.id.uuidString, rootID: rootID, url: Self.remoteURL(source: source.id, path: media.path),
        relativePath: original, folderRelativePath: "", name: media.name, format: format, fileSize: media.size,
        createdAt: nil, modifiedAt: nil, fileIdentifier: nil,
        companions: companions.map { AssetFile(url: Self.remoteURL(source: source.id, path: $0.path), relativePath: $0.path, size: $0.size, modifiedAt: nil, identifier: nil) },
        archiveID: record.id)
      photo.remote = RemoteAssetReference(source: source, listingID: listingID, entry: media, companions: companions,
        archiveRoot: root, recordID: record.id)
      photo.remote?.originals = record.originals
      return photo
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  private func renew(source: BridgeSource, path: String, key: String) async throws -> ScanResult {
    let consumer = UUID(), renewal: Renewal
    if let pending = renewals[key] {
      renewal = pending; renewals[key]?.consumers.insert(consumer)
    } else {
      renewal = Renewal(id: UUID(), task: Task { try await self.list(source: source, path: path) }, consumers: [consumer])
      renewals[key] = renewal
    }
    return try await withTaskCancellationHandler {
      do {
        let result = try await renewal.task.value
        releaseRenewal(key, id: renewal.id, consumer: consumer)
        try Task.checkCancellation()
        return result
      } catch { releaseRenewal(key, id: renewal.id, consumer: consumer); throw error }
    } onCancel: { Task { await self.releaseRenewal(key, id: renewal.id, consumer: consumer) } }
  }
  private func releaseRenewal(_ key: String, id: UUID, consumer: UUID) {
    guard renewals[key]?.id == id else { return }
    renewals[key]?.consumers.remove(consumer)
    if renewals[key]?.consumers.isEmpty == true, let task = renewals.removeValue(forKey: key)?.task { retire(task) }
  }
  private func trimCache(incoming: Int64) {
    var total = cache.values.reduce(Int64(0)) { $0 + $1.0.size }
    for (key, value) in cache.sorted(by: { $0.value.1 < $1.value.1 }) where total + incoming > cacheLimit {
      if let pinnedPrefix, key.hasPrefix(pinnedPrefix) { continue }
      try? FileManager.default.removeItem(at: value.0.url.deletingLastPathComponent())
      cache.removeValue(forKey: key); total -= value.0.size
    }
  }
  private func retire<Value>(_ task: Task<Value, Error>) {
    task.cancel()
    let id = UUID()
    draining[id] = Task { _ = try? await task.value; self.draining.removeValue(forKey: id) }
  }
  public func shutdown() async {
    if let shutdownTask { await shutdownTask.value; return }
    stopped = true
    let task = Task { await self.clear() }
    shutdownTask = task
    await task.value
  }
  public func clear() async {
    for flight in previewFlights.values { retire(flight.task) }; previewFlights.removeAll()
    for flight in flights.values { retire(flight.task) }; flights.removeAll()
    for renewal in renewals.values { retire(renewal.task) }; renewals.removeAll()
    while !draining.isEmpty { for task in Array(draining.values) { await task.value } }
    while !releases.isEmpty { for task in Array(releases.values) { await task.value } }
    cache.removeAll(); validatedPreviews.removeAll(); latestListings.removeAll(); pinnedPrefix = nil
    try? FileManager.default.removeItem(at: cacheRoot)
    await previews.clear()
  }
  private func send(_ request: BridgeRequest) async throws -> BridgeResponse {
    guard !stopped else { throw CancellationError() }
    try Task.checkCancellation()
    do {
      let response = try await transport(request)
      do {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        return try response.checked()
      } catch {
        if response.version == FrameBridgeEnvironment.protocolVersion { release(response.jobID) }
        throw error
      }
    } catch let error as BridgeError {
      if error.sessionFailure != nil { await sessionFailure(error) }
      throw error
    }
  }
  private func release(_ id: UUID?) {
    guard let id, releases[id] == nil else { return }
    let transport = self.transport
    releases[id] = Task {
      var request = BridgeRequest("release"); request.jobID = id
      _ = try? await transport(request)
      self.releases.removeValue(forKey: id)
    }
  }
  private func operation(_ request: BridgeRequest, photoID: String? = nil) async throws -> BridgeResponse {
    var jobID: UUID?
    do {
      var response = try await send(request)
      jobID = response.jobID
      let deadline = ContinuousClock.now.advanced(by: .seconds(180))
      while response.status == "pending" {
        try Task.checkCancellation()
        guard let id = response.jobID, ContinuousClock.now < deadline else { throw BridgeError("Remote request timed out. Retry when the host is available.") }
        if let photoID {
          let done = ByteCountFormatter.string(fromByteCount: response.completedBytes ?? 0, countStyle: .file)
          let total = ByteCountFormatter.string(fromByteCount: response.totalBytes ?? 0, countStyle: .file)
          progress(photoID, "Downloading \(done) / \(total)")
        }
        // RelayBar answers a status request when the job changes or, during a transfer, with its progress.
        await Task.yield()
        var status = BridgeRequest("status"); status.jobID = id
        response = try await send(status)
      }
      if let photoID { progress(photoID, nil) }
      if let error = response.error { throw BridgeError(error) }
      return response
    } catch {
      release(jobID)
      if let photoID { progress(photoID, nil) }
      if error is CancellationError, ["archive", "restore", "delete", "deleteBatch"].contains(request.operation) {
        throw BridgeError("Remote change was interrupted. Refresh to check which files remain before trying again.")
      }
      throw error
    }
  }
}
