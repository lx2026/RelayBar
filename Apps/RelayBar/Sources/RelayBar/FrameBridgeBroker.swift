import BridgeProtocol
import AssetGrouping
import AppKit
import CryptoKit
import Foundation
import Composition
import Security

/// Remote-file authority for the separately sandboxed Frame viewer.
@MainActor
final class FrameBridgeBroker {
    private var listener: BridgeSocketServer?
    private let work = EffectScope()
    private var retirement: Task<Void, Never>?
    private var stopped = false
    private var startupError: String?
    private var servers: [String: RemoteServer] = [:]
    private var services: [String: any RemoteFileServing] = [:]
    private var serviceEffects = EffectScope()
    private var serviceRetirement: Task<Void, Never>?
    private var serviceRetirementID = UUID()
    private var listings: [UUID: Listing] = [:]
    private var jobs: [UUID: Job] = [:]
    private var handoffs: [UUID: (Date, BridgeHandoff)] = [:]
    private let catalog: RemoteServerCatalog
    private let defaults: UserDefaults
    private let tunnels: () -> [Tunnel]
    private let available: () -> Bool
    private let socketRoot: () throws -> URL
    private let makeService: () -> any RemoteFileServing
    private let session = UUID()
    private var cacheRoot: URL?
    private var expiryTimer: Timer?
    private struct Listing { let sourceID: String; let path: String; let entries: [BridgeEntry]; let date: Date }
    private struct Job {
        var task: Task<Void, Never>?
        var response: BridgeResponse
        let date: Date
        var directory: URL?
        /// The session that asked for this work. When its connection ends, the job ends with it.
        let connection: UUID?
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }
    /// Set while a request is being handled, so work it starts is owned by that request's connection.
    private var requestingConnection: UUID?

    init(catalog: RemoteServerCatalog = .appDefault(), defaults: UserDefaults = .standard,
         tunnels: @escaping () -> [Tunnel] = { [] },
         available: @escaping () -> Bool = { true },
         socketRoot: @escaping () throws -> URL = FrameBridgeEnvironment.root,
         makeService: @escaping () -> any RemoteFileServing = {
             SFTPRemoteFileService(previewSizeLimit: 100 * 1_024 * 1_024,
                                   videoPreviewSizeLimit: 100 * 1_024 * 1_024,
                                   standardOutputLimit: 8 * 1_024 * 1_024)
         }) {
        self.catalog = catalog; self.defaults = defaults; self.tunnels = tunnels; self.makeService = makeService
        self.available = available; self.socketRoot = socketRoot
    }
    var isAllowed: Bool { defaults.bool(forKey: "frameViewer.readAccess.v1") }
    func start() {
        guard !stopped, listener == nil else { return }
        do {
            let group = try socketRoot()
            listener = try BridgeSocketServer(url: group.appendingPathComponent("viewer.sock"), onDisconnect: { [weak self] connection in
                Task { @MainActor in self?.disconnected(connection) }
            }) { [weak self] request, connection in
                await self?.respond(request, connection: connection) ?? BridgeResponse(error: "RelayBar is closing.")
            }
            cacheRoot = group.appendingPathComponent("FrameTransfers-\(session)")
            try FileManager.default.createDirectory(at: cacheRoot!, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.expire() }
            }
            startupError = nil
        } catch { startupError = error.localizedDescription; listener = nil }
    }
    func revoke() {
        defaults.set(false, forKey: "frameViewer.readAccess.v1")
        handoffs.removeAll(); listings.removeAll()
        let pending = jobs.values.compactMap(\.task)
        for id in Array(jobs.keys) { release(id) }
        retireServices(waitingFor: pending)
        // Frame learns at once, with the reason, instead of on its next request.
        listener?.disconnectAll(BridgeResponse(error: Self.unauthorized, sessionFailure: .unauthorized))
    }
    private static let unauthorized = "Open a folder in RelayBar and choose Open in Frame to allow remote viewing."
    /// The most one original download may transfer.
    private static let originalLimit: Int64 = 100 * 1_024 * 1_024

    /// A session's connection has ended: Frame quit, crashed, or closed it. Its work stops now.
    func disconnected(_ connection: UUID) {
        for (id, job) in jobs where job.connection == connection { release(id) }
    }

    /// Serves one call from a session. A status request for a job still in flight is answered when
    /// the job changes, or after a short interval with its progress, so Frame never polls on a timer.
    func respond(_ request: BridgeRequest, connection: UUID) async -> BridgeResponse {
        if request.operation == "status", let id = request.jobID, jobs[id]?.task != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard jobs[id] != nil else { continuation.resume(); return }
                let waiter = UUID()
                jobs[id]?.waiters[waiter] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.jobs[id]?.waiters.removeValue(forKey: waiter)?.resume()
                }
            }
        }
        return handle(request, connection: connection)
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        expiryTimer?.invalidate(); expiryTimer = nil
        let endpoint = listener; listener = nil; endpoint?.stop()
        let pending = jobs.values.compactMap(\.task)
        for id in Array(jobs.keys) { release(id) }
        retireServices(waitingFor: pending)
        listings.removeAll(); handoffs.removeAll(); servers.removeAll()
        let root = cacheRoot; cacheRoot = nil
        retirement = Task {
            await endpoint?.close()
            await work.dispose()
            await serviceRetirement?.value
            if let root { try? FileManager.default.removeItem(at: root) }
        }
    }
    func shutdown() async { stop(); await retirement?.value }
    private func source(_ server: RemoteServer) -> BridgeSource {
        let identity = ([server.sshHost] + server.additionalArguments).map { "\($0.utf8.count):\($0)" }.joined()
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        servers[id] = server
        return BridgeSource(id: id, name: server.name)
    }
    private func catalogResponse() -> BridgeResponse {
        var result = BridgeResponse()
        let tunnels = tunnels()
        result.sources = catalog.servers(from: tunnels).map(source)
        result.locations = catalog.recentLocations(from: tunnels).map { location in
            BridgeLocation(id: location.id.uuidString, source: source(location.server), path: location.path)
        }
        return result
    }
    func openInFrame(server: RemoteServer, path: String, focus: [String]) {
        guard FrameBridgeEnvironment.validPath(path) else { showError("This remote path cannot be opened in Frame."); return }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FrameBridgeEnvironment.frameBundle) else {
            showError("Frame isn’t installed. The download link is not available yet."); return
        }
        guard let version = Bundle(url: application)?.object(forInfoDictionaryKey: "FrameBridgeVersion") as? Int,
              version == FrameBridgeEnvironment.protocolVersion else {
            showError("Update Frame to a version that supports RelayBar remote folders."); return
        }
        do { try FrameBridgeEnvironment.verifyApplication(application, bundleID: FrameBridgeEnvironment.frameBundle) }
        catch { showError(error.localizedDescription); return }
        start()
        guard listener != nil else { showError(startupError ?? "The local viewer bridge is unavailable."); return }
        if !isAllowed {
            let alert = NSAlert()
            alert.messageText = "Allow Frame to access remote folders?"
            alert.informativeText = "Frame can view, archive and permanently delete remote files. SSH credentials stay in RelayBar. Revoke access in Settings."
            alert.addButton(withTitle: "Allow & Open"); alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            defaults.set(true, forKey: "frameViewer.readAccess.v1")
        }
        let nonce = UUID()
        handoffs[nonce] = (.now, BridgeHandoff(source: source(server), path: RemotePath.normalized(path),
                                             focus: Array(focus.filter(FrameBridgeEnvironment.validName).prefix(1_000))))
        let url = URL(string: "frame-viewer://handoff/\(nonce.uuidString)")!
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.showError(error.localizedDescription) } }
        }
    }
    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Open in Frame"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    private func service(_ sourceID: String) throws -> any RemoteFileServing {
        if let service = services[sourceID] { return service }
        guard serviceRetirement == nil else { throw BridgeError("Remote viewer is busy. Retry shortly.") }
        if services.count >= 8 {
            guard work.count == 0 else { throw BridgeError("Remote viewer is busy. Retry shortly.") }
            retireServices()
            throw BridgeError("Remote viewer is busy. Retry shortly.")
        }
        let service = makeService()
        try serviceEffects.own { await service.shutdownAndWait() }
        services[sourceID] = service
        return service
    }
    private func retireServices(waitingFor pending: [Task<Void, Never>] = []) {
        let retired = serviceEffects, previous = serviceRetirement
        let token = UUID(); serviceRetirementID = token
        serviceEffects = EffectScope()
        for service in services.values { service.shutdown() }
        services.removeAll()
        serviceRetirement = Task { [weak self] in
            await previous?.value
            for task in pending { await task.value }
            await retired.dispose()
            if self?.serviceRetirementID == token { self?.serviceRetirement = nil }
        }
    }
    func handle(_ request: BridgeRequest, connection: UUID? = nil) -> BridgeResponse {
        guard !stopped, available() else { return BridgeResponse(error: "RelayBar is closing.", sessionFailure: .unavailable) }
        guard request.version == FrameBridgeEnvironment.protocolVersion else { return BridgeResponse(error: "Update Frame and RelayBar to compatible versions.", sessionFailure: .incompatible) }
        guard isAllowed else { return BridgeResponse(error: Self.unauthorized, sessionFailure: .unauthorized) }
        requestingConnection = connection
        defer { requestingConnection = nil }
        expire()
        switch request.operation {
        case "catalog": return catalogResponse()
        case "rememberOpen":
            // Compatibility no-op. Only RelayBar's own navigation writes its history.
            return BridgeResponse()
        case "handoff":
            guard let nonce = request.nonce, let value = handoffs.removeValue(forKey: nonce), value.0.timeIntervalSinceNow > -60 else {
                return BridgeResponse(error: "This handoff expired. Choose Open in Frame in RelayBar again.")
            }
            var response = catalogResponse(); response.handoff = value.1; return response
        case "status":
            guard let id = request.jobID, let job = jobs[id] else { return BridgeResponse(error: "This request expired. Refresh the remote folder.") }
            return job.response
        case "cancel", "release":
            if let id = request.jobID { release(id) }; return BridgeResponse()
        case "preview", "archive", "delete", "restore", "collection":
            return assetOperation(request)
        case "deleteBatch": return deleteBatch(request)
        case "documentStat":
            guard let sourceID = request.sourceID, let server = servers[sourceID], let root = request.root,
                  FrameBridgeEnvironment.validPath(root), let paths = request.paths, !paths.isEmpty, paths.count <= 128,
                  paths.allSatisfy({ FrameBridgeEnvironment.validPath($0) && $0.hasPrefix(root == "/" ? "/" : root + "/") }),
                  work.count < 4, jobs.count < 32 else {
                return BridgeResponse(error: "Invalid document resources or remote viewer is busy.")
            }
            do {
                let service = try service(sourceID)
                var input = BridgeAssetInput(action: "documentStat", root: root); input.paths = paths
                return begin { [weak self] id in
                    do {
                        let result = try await service.frameAsset(server: server, input: input)
                        var response = BridgeResponse(); response.asset = result
                        self?.finish(id, response)
                    } catch { self?.finish(id, BridgeResponse(error: error.localizedDescription)) }
                }
            } catch { return BridgeResponse(error: error.localizedDescription) }
        case "list":
            guard let sourceID = request.sourceID, let server = servers[sourceID], let path = request.path,
                  FrameBridgeEnvironment.validPath(path) else { return BridgeResponse(error: "Choose a saved RelayBar host and an absolute folder path.") }
            guard work.count < 4, jobs.count < 32 else { return BridgeResponse(error: "Remote viewer is busy. Retry shortly.") }
            do {
                let service = try service(sourceID)
                return begin { [weak self] id in
                    do {
                        let result = try await service.frameAsset(server: server, input: BridgeAssetInput(action: "list", root: path))
                        let entries = result.entries ?? []
                        try Task.checkCancellation()
                        guard entries.count <= 10_000 else { throw BridgeError("This folder exceeds 10,000 entries. Open a smaller folder.") }
                        guard let self, self.jobs[id] != nil else { return }
                        let listingID = UUID()
                        if self.listings.count >= 32, let oldest = self.listings.min(by: { $0.value.date < $1.value.date })?.key {
                            self.listings.removeValue(forKey: oldest)
                        }
                        self.listings[listingID] = Listing(sourceID: sourceID, path: path, entries: entries, date: .now)
                        var response = BridgeResponse(); response.listingID = listingID
                        response.entries = entries
                        self.finish(id, response)
                    } catch { self?.finish(id, BridgeResponse(error: error.localizedDescription)) }
                }
            } catch { return BridgeResponse(error: error.localizedDescription) }
        case "fetch":
            // The name becomes a local file name below, so it must be one path component.
            guard let listingID = request.listingID, let listing = listings[listingID], let name = request.name,
                  FrameBridgeEnvironment.validName(name),
                  let entry = listing.entries.first(where: { $0.name == name && !$0.directory && (request.path == nil || $0.path == request.path) }),
                  let server = servers[listing.sourceID], let cacheRoot else { return BridgeResponse(error: "Refresh this remote folder before downloading.") }
            guard entry.size >= 0, entry.size <= Self.originalLimit else {
                return BridgeResponse(error: "This file exceeds 100 MiB. Download it in RelayBar.")
            }
            let size = entry.size
            guard work.count < 4, jobs.count < 32,
                  jobs.values.filter({ $0.directory != nil }).count < 8 else { return BridgeResponse(error: "Remote viewer cache is busy. Retry shortly.") }
            do {
                let service = try service(listing.sourceID)
                return begin(totalBytes: size) { [weak self] id in
                    var temporary: URL?
                    do {
                        // Refresh exact identity before transferring an explicitly requested original.
                        var check = BridgeAssetInput(action: "stat", root: listing.path)
                        check.members = [entry]; check.pixels = 0
                        _ = try await service.frameAsset(server: server, input: check)
                        let remoteEntry = RemoteFileEntry(name: entry.name, path: entry.path, kind: .file, size: entry.size, modificationText: entry.modified)
                        // Bounded by this request's limit alone, not by RelayBar's own preview limits.
                        let file = try await service.prepareOriginal(server: server, entry: remoteEntry,
                                                                     maximumBytes: Self.originalLimit) { bytes in
                            Task { @MainActor in self?.jobs[id]?.response.completedBytes = bytes }
                        }
                        temporary = file.deletingLastPathComponent()
                        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                        try Task.checkCancellation()
                        _ = try await service.frameAsset(server: server, input: check)
                        guard let self, self.jobs[id] != nil else { return }
                        let actual = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard actual.isRegularFile == true, actual.isSymbolicLink != true, Int64(actual.fileSize ?? -1) == size else {
                            throw BridgeError("The remote file changed during download. Refresh and retry.")
                        }
                        let directory = cacheRoot.appendingPathComponent(id.uuidString)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                        self.jobs[id]?.directory = directory
                        try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(name))
                        var response = BridgeResponse(); response.completedBytes = size; response.totalBytes = size
                        response.cacheRelativePath = "\(cacheRoot.lastPathComponent)/\(id)/\(name)"
                        self.finish(id, response)
                    } catch {
                        if let temporary { try? FileManager.default.removeItem(at: temporary) }
                        self?.finish(id, BridgeResponse(error: error.localizedDescription))
                    }
                }
            } catch { return BridgeResponse(error: error.localizedDescription) }
        default: return BridgeResponse(error: "This bridge operation is not supported.")
        }
    }
    private func assetOperation(_ request: BridgeRequest) -> BridgeResponse {
        let mutation = ["archive", "delete", "restore"].contains(request.operation)
        guard work.count < 4, jobs.count < 32 else {
            return BridgeResponse(error: "Remote viewer is busy. Retry shortly.")
        }
        let listing = request.listingID.flatMap { listings[$0] }
        guard let sourceID = listing?.sourceID ?? request.sourceID, let server = servers[sourceID],
              let root = request.root ?? listing?.path, FrameBridgeEnvironment.validPath(root) else {
            return BridgeResponse(error: "Refresh this remote folder before downloading.")
        }
        var input = BridgeAssetInput(action: request.operation, root: root)
        input.recordID = request.recordID
        input.pixels = request.pixels; input.fingerprint = request.fingerprint
        if ["preview", "archive", "delete"].contains(request.operation) {
            guard let listing, let entry = listing.entries.first(where: {
                !$0.directory && $0.name == request.name && (request.path == nil || $0.path == request.path)
            }), AssetCompanionNames.isPrimary(entry.name),
            request.operation != "preview" || AssetCompanionNames.isMedia(entry.name) else {
                return BridgeResponse(error: "Refresh this remote folder before downloading.")
            }
            input.members = [entry] + Self.companions(for: entry, entries: listing.entries)
            if mutation {
                guard entry.path.hasPrefix(root == "/" ? "/" : root + "/") else { return BridgeResponse(error: "Asset is outside this folder.") }
            }
        }
        if request.operation == "restore" && request.recordID == nil { return BridgeResponse(error: "Choose an archived asset.") }
        do {
            let service = try service(sourceID)
            return begin { [weak self] id in
                do {
                    let result = try await service.frameAsset(server: server, input: input)
                    guard let self, self.jobs[id] != nil else { return }
                    var response = BridgeResponse(); response.asset = result
                    if request.operation == "collection", let records = result.records {
                        let listingID = UUID()
                        if self.listings.count >= 32, let oldest = self.listings.min(by: { $0.value.date < $1.value.date })?.key {
                            self.listings.removeValue(forKey: oldest)
                        }
                        self.listings[listingID] = Listing(sourceID: sourceID, path: root,
                            entries: records.flatMap(\.members), date: .now)
                        response.listingID = listingID
                    }
                    self.finish(id, response)
                } catch { self?.finish(id, BridgeResponse(error: error.localizedDescription)) }
            }
        } catch { return BridgeResponse(error: error.localizedDescription) }
    }
    private func deleteBatch(_ request: BridgeRequest) -> BridgeResponse {
        guard let sourceID = request.sourceID, let server = servers[sourceID],
              let root = request.root, FrameBridgeEnvironment.validPath(root),
              let targets = request.targets, !targets.isEmpty,
              targets.count <= FrameBridgeEnvironment.maximumBatchAssets,
              Set(targets.map(\.path)).count == targets.count else {
            return BridgeResponse(error: "Invalid deletion selection.")
        }
        guard work.count < 4, jobs.count < 32 else {
            return BridgeResponse(error: "Remote viewer is busy. Retry shortly.")
        }
        var batch: [BridgeAssetInput] = []
        var groups: [UUID: [String: [BridgeEntry]]] = [:]
        for target in targets {
            guard let listing = listings[target.listingID], listing.sourceID == sourceID,
                  let entry = listing.entries.first(where: { $0.path == target.path && !$0.directory }),
                  AssetCompanionNames.isPrimary(entry.name),
                  entry.path.hasPrefix(root == "/" ? "/" : root + "/") else {
                return BridgeResponse(error: "Refresh this remote folder before deleting.")
            }
            var asset = BridgeAssetInput(action: "delete", root: root)
            if groups[target.listingID] == nil { groups[target.listingID] = Self.companionGroups(listing.entries) }
            asset.members = [entry] + (groups[target.listingID]?[entry.path] ?? [])
            asset.recordID = target.recordID
            batch.append(asset)
        }
        var input = BridgeAssetInput(action: "deleteBatch", root: root); input.batch = batch
        do {
            let service = try service(sourceID)
            return begin { [weak self] id in
                do {
                    let result = try await service.frameAsset(server: server, input: input)
                    var response = BridgeResponse(); response.asset = result
                    self?.finish(id, response)
                } catch { self?.finish(id, BridgeResponse(error: error.localizedDescription)) }
            }
        } catch { return BridgeResponse(error: error.localizedDescription) }
    }
    nonisolated static func companions(for entry: BridgeEntry, entries: [BridgeEntry]) -> [BridgeEntry] {
        companionGroups(entries)[entry.path] ?? []
    }
    nonisolated private static func companionGroups(_ entries: [BridgeEntry]) -> [String: [BridgeEntry]] {
        let files = entries.filter { !$0.directory }
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let media = files.filter { AssetCompanionNames.isMedia($0.path) }.map(\.path)
        return AssetCompanionNames.groups(media: media, files: files.map(\.path)).mapValues { $0.compactMap { byPath[$0] } }
    }
    private func begin(totalBytes: Int64? = nil, action: @escaping @MainActor (UUID) async -> Void) -> BridgeResponse {
        let id = UUID()
        var pending = BridgeResponse(); pending.status = "pending"; pending.jobID = id; pending.totalBytes = totalBytes
        jobs[id] = Job(task: nil, response: pending, date: .now, connection: requestingConnection)
        do { jobs[id]?.task = try work.task { await action(id) } }
        catch { jobs.removeValue(forKey: id); return BridgeResponse(error: "RelayBar is closing.") }
        return pending
    }
    private func finish(_ id: UUID, _ result: BridgeResponse) {
        guard jobs[id] != nil else { return }
        var result = result; result.jobID = id
        jobs[id]?.response = result; jobs[id]?.task = nil
        wake(id)
    }
    private func wake(_ id: UUID) {
        guard let waiters = jobs[id]?.waiters, !waiters.isEmpty else { return }
        jobs[id]?.waiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }
    private func release(_ id: UUID) {
        wake(id)
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.task?.cancel()
        if let directory = job.directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func expire() {
        handoffs = handoffs.filter { $0.value.0.timeIntervalSinceNow > -60 }
        listings = listings.filter { $0.value.date.timeIntervalSinceNow > -3_600 }
        // A session's jobs end with its connection. Only work with no connection behind it can be orphaned.
        for id in jobs.keys.filter({ jobs[$0]!.connection == nil && jobs[$0]!.date.timeIntervalSinceNow < -300 }) { release(id) }
    }
}

extension Notification.Name {
    static let frameRemoteHistoryChanged = Notification.Name("FrameRemoteHistoryChanged")
}
