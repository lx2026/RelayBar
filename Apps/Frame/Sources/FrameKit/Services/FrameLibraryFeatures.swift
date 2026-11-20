import Combine
import Composition
import Foundation
import SwiftData

struct LibraryRootInfo: Sendable {
    let id: UUID
    let displayName: String
}

struct LibraryLocation: Sendable {
    let root: LibraryRootInfo
    let url: URL
}

/// Domain data stays in the app's existing catalog, outside feature configuration.
@MainActor
final class FrameLibraryData {
    let context: ModelContext
    let defaults: UserDefaults
    let scanner: FrameLibraryFeatures.Scanner
    init(context: ModelContext, defaults: UserDefaults, scanner: @escaping FrameLibraryFeatures.Scanner) {
        self.context = context; self.defaults = defaults; self.scanner = scanner
    }
}

@MainActor
final class FrameCatalogFeature {
    private weak var context: FeatureContext?
    private let library: FrameLibraryData
    private let access: FrameLocalAccessFeature
    var isActive: Bool { context?.isActive == true }
    init(_ context: FeatureContext, data: FrameLibraryData, access: FrameLocalAccessFeature) {
        self.context = context; library = data; self.access = access
    }
    private func data() throws -> FrameLibraryData {
        guard let context else { throw CompositionError("Folder catalog is unavailable.") }
        try context.checkActive()
        return library
    }
    private func records(_ data: FrameLibraryData) throws -> [LibraryRootRecord] {
        try data.context.fetch(FetchDescriptor<LibraryRootRecord>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]))
    }
    private func info(_ record: LibraryRootRecord) -> LibraryRootInfo { .init(id: record.id, displayName: record.displayName) }
    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    private func resolve(_ record: LibraryRootRecord, data: FrameLibraryData) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: record.bookmarkData, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let bookmark = try? bookmark(url) { record.bookmarkData = bookmark; try? data.context.save() }
        }
        return url
    }
    func record(_ id: UUID) throws -> LibraryRootInfo? {
        let data = try data()
        return try records(data).first { $0.id == id }.map(info)
    }
    func open(_ url: URL, replacing id: UUID? = nil) throws -> LibraryLocation {
        let data = try data()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let existing = try records(data).first { record in
            if let id { return record.id == id }
            return (try? resolve(record, data: data).resolvingSymlinksInPath().standardizedFileURL.path)
                == url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let bytes = try bookmark(url)
        let record = existing ?? LibraryRootRecord(id: UUID(), displayName: url.lastPathComponent, bookmarkData: bytes)
        if existing == nil { data.context.insert(record) }
        record.bookmarkData = bytes; record.displayName = url.lastPathComponent; record.lastOpenedAt = .now
        try data.context.save()
        let hidden = (data.defaults.stringArray(forKey: "hiddenRecentRoots") ?? []).filter { $0 != record.id.uuidString }
        data.defaults.set(hidden, forKey: "hiddenRecentRoots")
        return LibraryLocation(root: info(record), url: url)
    }
    func recent(_ id: UUID) throws -> LibraryLocation {
        let data = try data()
        guard let record = try records(data).first(where: { $0.id == id }) else { throw CompositionError("Folder is no longer in the catalog.") }
        let url = try resolve(record, data: data)
        record.lastOpenedAt = .now; try data.context.save()
        return LibraryLocation(root: info(record), url: url)
    }
    func authorizedRoot(_ id: UUID, matching url: URL) throws -> URL {
        let data = try data()
        guard let record = try records(data).first(where: { $0.id == id }) else { throw CompositionError("Choose this folder again.") }
        let authorized = try resolve(record, data: data)
        let scoped = authorized.startAccessingSecurityScopedResource()
        defer { if scoped { authorized.stopAccessingSecurityScopedResource() } }
        guard authorized.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw CompositionError("The folder location changed. Open it again before reading.")
        }
        return authorized
    }
    func activate(_ url: URL, rootID: UUID) throws {
        let authorized = try authorizedRoot(rootID, matching: url)
        try access.activate(authorized, rootID: rootID)
    }
    func hide(_ id: UUID) throws {
        let data = try data()
        var hidden = Set(data.defaults.stringArray(forKey: "hiddenRecentRoots") ?? [])
        hidden.insert(id.uuidString); data.defaults.set(Array(hidden), forKey: "hiddenRecentRoots")
    }
    func recents() throws -> [RecentFolder] {
        let data = try data(), hidden = Set(data.defaults.stringArray(forKey: "hiddenRecentRoots") ?? [])
        var seen = Set<String>()
        return try records(data).compactMap { record -> RecentFolder? in
            guard !hidden.contains(record.id.uuidString) else { return nil }
            let url = try? resolve(record, data: data)
            let key = url?.resolvingSymlinksInPath().standardizedFileURL.path ?? record.id.uuidString
            guard seen.insert(key).inserted else { return nil }
            let scoped = url?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
            let available = url.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
            return RecentFolder(id: record.id, name: record.displayName,
                                parentPath: url?.deletingLastPathComponent().path ?? "Location unavailable", available: available)
        }.prefix(8).map { $0 }
    }
}

@MainActor
final class FrameFavoritesFeature {
    private weak var context: FeatureContext?
    private let library: FrameLibraryData
    var isActive: Bool { context?.isActive == true }
    init(_ context: FeatureContext, data: FrameLibraryData) { self.context = context; library = data }
    private func model() throws -> ModelContext {
        guard let context else { throw CompositionError("Pins are unavailable.") }
        try context.checkActive()
        return library.context
    }
    func favorites(rootID: UUID) throws -> Set<PhotoItem.ID> {
        let records = try model().fetch(FetchDescriptor<FavoriteRecord>())
        return Set(records.filter { $0.rootID == rootID && $0.isFavorite }.map(\.key))
    }
    func set(_ photos: [PhotoItem], favorite: Bool) throws {
        let model = try model(), records = try model.fetch(FetchDescriptor<FavoriteRecord>())
        var byKey = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for photo in photos {
            if let record = byKey[photo.favoriteID] { record.isFavorite = favorite }
            else {
                let record = FavoriteRecord(rootID: photo.rootID, relativePath: photo.relativePath, isFavorite: favorite)
                model.insert(record); byKey[photo.favoriteID] = record
            }
        }
        try model.save()
    }

    // Opened times and folder baselines live beside the favourites, keyed the same way. A catalog made without
    // their models (an older schema) simply has no markers.
    private var tracksOpening: Bool {
        let names = Set(library.context.container.schema.entities.map(\.name))
        return names.contains("OpenedFileRecord") && names.contains("FolderBaselineRecord")
    }
    /// The library's folder baselines by folder path and the files' opened times by key, or nil without the models.
    func changeState(rootID: UUID) throws -> (baselines: [String: Date], opened: [String: Date])? {
        guard tracksOpening else { return nil }
        let model = try model()
        let baselines = try model.fetch(FetchDescriptor<FolderBaselineRecord>()).filter { $0.rootID == rootID }
        let opened = try model.fetch(FetchDescriptor<OpenedFileRecord>()).filter { $0.rootID == rootID }
        return (Dictionary(baselines.map { ($0.folderPath, $0.baseline) }, uniquingKeysWith: { first, _ in first }),
                Dictionary(opened.map { ($0.key, $0.openedAt) }, uniquingKeysWith: { first, _ in first }))
    }
    /// Records a folder's baseline the first time it is listed; an existing one is kept. Returns the one in force.
    func recordBaseline(rootID: UUID, folder: String, baseline: Date) throws -> Date? {
        guard tracksOpening else { return nil }
        let model = try model()
        let key = FavoriteRecord.makeKey(rootID: rootID, relativePath: folder)
        if let record = try model.fetch(FetchDescriptor<FolderBaselineRecord>()).first(where: { $0.key == key }) { return record.baseline }
        model.insert(FolderBaselineRecord(rootID: rootID, folderPath: folder, baseline: baseline))
        try model.save()
        return baseline
    }
    func markOpened(rootID: UUID, relativePath: String, at date: Date) throws {
        guard tracksOpening else { return }
        let model = try model()
        let key = FavoriteRecord.makeKey(rootID: rootID, relativePath: relativePath)
        if let record = try model.fetch(FetchDescriptor<OpenedFileRecord>()).first(where: { $0.key == key }) {
            record.openedAt = date; record.held = false
        } else {
            model.insert(OpenedFileRecord(rootID: rootID, relativePath: relativePath, openedAt: date))
        }
        try model.save()
    }
    /// Keeps these entries while Frame moves their files to the Trash or the Archive.
    func holdOpened(keys: Set<String>) throws {
        guard tracksOpening, !keys.isEmpty else { return }
        let model = try model()
        for record in try model.fetch(FetchDescriptor<OpenedFileRecord>()) where keys.contains(record.key) { record.held = true }
        try model.save()
    }
    /// Drops the entries of files deleted for good: those in `keys` always, those in `heldKeys` only while still
    /// held (a released entry belongs to a file listed at that path since). Returns the keys dropped.
    @discardableResult
    func forgetOpened(keys: Set<String>, heldKeys: Set<String>) throws -> [String] {
        guard tracksOpening, !keys.isEmpty || !heldKeys.isEmpty else { return [] }
        let model = try model()
        var dropped: [String] = []
        for record in try model.fetch(FetchDescriptor<OpenedFileRecord>())
        where keys.contains(record.key) || (record.held && heldKeys.contains(record.key)) {
            dropped.append(record.key); model.delete(record)
        }
        if model.hasChanges { try model.save() }
        return dropped
    }
    /// Drops the opened times of `folder`'s files that its listing no longer has, except those Frame moved away
    /// itself; an entry whose file is listed again stops being held. Returns the keys dropped.
    @discardableResult
    func pruneOpened(rootID: UUID, folder: String, keeping paths: Set<String>) throws -> [String] {
        guard tracksOpening else { return [] }
        let model = try model()
        let records = try model.fetch(FetchDescriptor<OpenedFileRecord>()).filter {
            $0.rootID == rootID && ($0.relativePath as NSString).deletingLastPathComponent == folder
        }
        var dropped: [String] = []
        for record in records {
            if paths.contains(record.relativePath) {
                if record.held { record.held = false }
            } else if !record.held {
                dropped.append(record.key); model.delete(record)
            }
        }
        if model.hasChanges { try model.save() }
        return dropped
    }
}

@MainActor
final class FrameScanningFeature {
    private weak var context: FeatureContext?
    private let library: FrameLibraryData
    private let catalog: FrameCatalogFeature
    private let access: FrameLocalAccessFeature
    private let work: FrameFeatureWork
    private struct OwnedIndex { let index: LocalFolderIndex; let access: FrameLocalAccessLease }
    private var indexes: [UUID: OwnedIndex] = [:]
    private var closed = false
    var isActive: Bool { !closed && context?.isActive == true }
    init(_ context: FeatureContext, data: FrameLibraryData, catalog: FrameCatalogFeature, access: FrameLocalAccessFeature) {
        self.context = context; library = data; self.catalog = catalog; self.access = access
        work = FrameFeatureWork(context, access: access)
    }
    func makeIndex(root: URL, rootID: UUID) throws -> LocalFolderIndex {
        guard let context, !closed else { throw CompositionError("Local scanning is unavailable.") }
        try context.checkActive()
        let url = try catalog.authorizedRoot(rootID, matching: root)
        let access = try access.acquire([url], rootID: rootID)
        let index = LocalFolderIndex(root: root, rootID: rootID, authorize: { [weak context] in
            guard let context else { throw CancellationError() }
            try context.checkActive()
        })
        let id = UUID()
        indexes[id] = OwnedIndex(index: index, access: access)
        index.didShutdown = { [weak self] in self?.releaseIndex(id) }
        return index
    }
    private func releaseIndex(_ id: UUID) {
        indexes.removeValue(forKey: id)?.access.release()
    }
    func scan(root: URL, rootID: UUID) async throws -> ScanResult {
        guard let context, !closed else { throw CompositionError("Local scanning is unavailable.") }
        try context.checkActive()
        let authorized = try catalog.authorizedRoot(rootID, matching: root)
        let scanner = library.scanner
        let result = try await work.run(roots: [authorized], rootID: rootID) { try await scanner(root, rootID) }
        guard !closed else { throw CancellationError() }
        try context.checkActive()
        return result
    }
    func stop() { closed = true; work.cancel(); for owned in indexes.values { owned.index.stop() } }
    func shutdown() async {
        stop()
        for owned in Array(indexes.values) { await owned.index.shutdown() }
        for id in Array(indexes.keys) { releaseIndex(id) }
    }
}

// The local catalog, favourites and scanning exist once the app's SwiftData catalog is open.

struct CatalogFeature: Feature {
    @Constant var data: FrameLibraryData
    @Need(FrameServices.LocalAccess.self) var access
    @Offer(FrameServices.Catalog.self) var catalog

    func run(_ context: FeatureContext) async throws {
        catalog.set(FrameCatalogFeature(context, data: data, access: access))
    }
}

struct FavoritesFeature: Feature {
    @Constant var data: FrameLibraryData
    @Offer(FrameServices.Favorites.self) var favorites

    func run(_ context: FeatureContext) async throws { favorites.set(FrameFavoritesFeature(context, data: data)) }
}

struct ScanningFeature: Feature {
    @Constant var data: FrameLibraryData
    @Need(FrameServices.Catalog.self) var catalog
    @Need(FrameServices.LocalAccess.self) var access
    @Offer(FrameServices.Scanning.self) var scanning

    func run(_ context: FeatureContext) async throws {
        let feature = FrameScanningFeature(context, data: data, catalog: catalog, access: access)
        try context.effect("local scanning", cancel: { feature.stop() }) { await feature.shutdown() }
        scanning.set(feature)
    }
}

/// The shell's view of the local library. Each property is present while its feature is loaded.
@MainActor
public final class FrameLibraryFeatures {
    public typealias Scanner = @Sendable (URL, UUID) async throws -> ScanResult
    let accessOperations: FrameSecurityScopeOperations
    /// The open catalog. Its features join the tree once this is bound.
    private(set) var data: FrameLibraryData?
    private var defaults = UserDefaults.standard
    private var scanner: Scanner = { try FileScanner.scan(rootURL: $0, rootID: $1) }
    private var runtime: FeatureRuntime?
    var access: FrameLocalAccessFeature? { runtime?.service(FrameServices.LocalAccess.self) }
    var catalog: FrameCatalogFeature? { runtime?.service(FrameServices.Catalog.self) }
    var favorites: FrameFavoritesFeature? { runtime?.service(FrameServices.Favorites.self) }
    var scanning: FrameScanningFeature? { runtime?.service(FrameServices.Scanning.self) }
    public var canUseCatalog: Bool { catalog?.isActive == true }
    public var canFavorite: Bool { favorites?.isActive == true }
    public var canScan: Bool { scanning?.isActive == true }
    public init() { accessOperations = FrameSecurityScopeOperations() }
    init(accessOperations: FrameSecurityScopeOperations) { self.accessOperations = accessOperations }
    func attach(_ runtime: FeatureRuntime) { self.runtime = runtime }
    func closeLocalRoot() { access?.closeRoot() }
    func configure(defaults: UserDefaults, scanner: @escaping Scanner) {
        guard data == nil else { return }
        self.defaults = defaults; self.scanner = scanner
    }
    func bind(_ model: ModelContext) throws {
        if let data {
            guard data.context === model else { throw CompositionError("The library already uses another catalog.") }
        } else { data = FrameLibraryData(context: model, defaults: defaults, scanner: scanner) }
    }
}
