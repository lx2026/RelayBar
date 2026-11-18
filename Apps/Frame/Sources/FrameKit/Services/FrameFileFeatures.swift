import Combine
import Composition
import Foundation

struct TrashGroup: Sendable {
    let rootURL: URL
    let rootID: UUID
    let files: [TrashedFile]
}

struct TrashRestoreResult: Sendable {
    let group: TrashGroup
    let restored: [PhotoItem]
    let errors: [FileActionFailure]
}

struct ArchiveBatchResult: Sendable {
    var processed = 0
    var failures: [FileActionFailure] = []
}

/// Session domain data survives unloading the Trash feature. It is not a feature flag.
@MainActor
final class TrashHistory: ObservableObject {
    @Published var groups: [TrashGroup] = []
    var busy = false
}

struct FrameLocalFileOperations: Sendable {
    var trash: @Sendable ([PhotoItem], @escaping @Sendable (Int) async -> Void) async -> TrashBatchResult = {
        await BatchTrash.move($0, progress: $1)
    }
    var restore: @Sendable ([TrashedFile]) -> (restored: [PhotoItem], failed: [TrashedFile], errors: [FileActionFailure]) = { BatchTrash.restore($0) }
    var archive: @Sendable (PhotoItem, URL, Bool) throws -> Void = {
        if $2 { try ArchiveService.restore($0, root: $1) }
        else { try ArchiveService.archive($0, root: $1) }
    }
    /// Exports one file, replacing at the destination only what the third argument allows.
    var copy: @Sendable (URL, URL, ExactCopyExporter.Replacement) throws -> Void = {
        try ExactCopyExporter.export(source: $0, destination: $1, replacing: $2)
    }
    var planExport: @Sendable (PhotoItem, URL) async throws -> AssetExportPlan = { try AssetExporter.plan($0, folder: $1) }
    var exportGroup: @Sendable (AssetExportPlan) throws -> Void = { try AssetExporter.export($0) }
}

/// Owns the worker through its feature context. Cancellation stops admission/next items;
/// an already submitted filesystem transaction is joined, including its receipt.
@MainActor
final class FrameFeatureWork {
    weak var context: FeatureContext?
    private let access: FrameLocalAccessFeature?
    private var cancellations: [UUID: () -> Void] = [:]
    private var cancellationGeneration = UUID()
    var isActive: Bool { context?.isActive == true }
    /// `access` lends security-scoped folders to work that names local roots.
    init(_ context: FeatureContext, access: FrameLocalAccessFeature?) { self.context = context; self.access = access }
    func cancel() {
        cancellationGeneration = UUID()
        for cancel in cancellations.values { cancel() }
    }

    func run<Value: Sendable>(roots: [URL], rootID: UUID? = nil, allowRetired: Bool = false, operation: @escaping @Sendable () async throws -> Value,
                             receipt: @escaping @MainActor (Value) -> Void = { _ in }) async throws -> Value {
        try await run(job: {
            Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try await operation()
            }
        }, receipt: receipt, roots: roots, rootID: rootID, allowRetired: allowRetired)
    }

    func run<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try await run(job: { Task { try Task.checkCancellation(); return try await operation() } })
    }

    private func run<Value: Sendable>(job: @escaping @MainActor () -> Task<Value, Error>,
                                     receipt: @escaping @MainActor (Value) -> Void = { _ in },
                                     roots: [URL] = [], rootID: UUID? = nil, allowRetired: Bool = false) async throws -> Value {
        guard let context else { throw CompositionError("File feature is unavailable.") }
        try context.checkActive()
        let generation = cancellationGeneration
        return try await context.effects.run { [self] in
            try context.checkActive()
            guard generation == cancellationGeneration else { throw CancellationError() }
            let lease: FrameLocalAccessLease?
            if roots.isEmpty { lease = nil }
            else {
                guard let access else { throw CompositionError("Local folders are unavailable.") }
                lease = try access.acquire(roots, rootID: rootID, allowRetired: allowRetired)
            }
            defer { lease?.release() }
            let task = job()
            let id = UUID()
            cancellations[id] = { task.cancel() }
            defer { cancellations.removeValue(forKey: id) }
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            // Do not discard committed mutations merely because the context is now retiring.
            receipt(value)
            return value
        }
    }
}

@MainActor
final class FrameTrashFeature {
    private let work: FrameFeatureWork
    private let operations: FrameLocalFileOperations
    private let history: TrashHistory
    private let access: FrameLocalAccessFeature
    private weak var context: FeatureContext?
    var isActive: Bool { work.isActive }
    init(_ context: FeatureContext, operations: FrameLocalFileOperations, history: TrashHistory, access: FrameLocalAccessFeature) {
        self.context = context; self.operations = operations; self.history = history; self.access = access
        work = FrameFeatureWork(context, access: access)
    }
    func cancel() { work.cancel() }
    func move(_ photos: [PhotoItem], root: URL, rootID: UUID,
              progress: @escaping @MainActor (Int) -> Void) async throws -> TrashBatchResult {
        guard let context else { throw CompositionError("Trash is unavailable.") }
        try context.checkActive()
        let history = history
        guard !history.busy else { throw CompositionError("A Trash operation is already running.") }
        history.busy = true
        defer { history.busy = false }
        let savedRoot = try access.authorizedURL(for: root)
        let operation = operations.trash
        let report: @Sendable (Int) async -> Void = { count in
            await MainActor.run { if context.isActive { progress(count) } }
        }
        return try await work.run(roots: [root], rootID: rootID, operation: { await operation(photos, report) }) { result in
            let files = result.successes + result.partialRecoveries
            if !files.isEmpty {
                history.groups.append(TrashGroup(rootURL: savedRoot, rootID: rootID, files: files))
                if history.groups.count > 20 { history.groups.removeFirst() }
            }
        }
    }
    func restoreLast() async throws -> TrashRestoreResult? {
        guard let context else { throw CompositionError("Trash is unavailable.") }
        try context.checkActive()
        let history = history
        guard !history.busy else { throw CompositionError("A Trash operation is already running.") }
        guard let group = history.groups.last else { return nil }
        history.busy = true
        defer { history.busy = false }
        let operation = operations.restore
        let result = try await work.run(roots: [group.rootURL], rootID: group.rootID, allowRetired: true, operation: { operation(group.files) }) { result in
            history.groups.removeLast()
            if !result.failed.isEmpty {
                history.groups.append(TrashGroup(rootURL: group.rootURL, rootID: group.rootID, files: result.failed))
            }
        }
        return TrashRestoreResult(group: group, restored: result.restored, errors: result.errors)
    }
}

@MainActor
final class FrameArchiveFeature {
    private let work: FrameFeatureWork
    private let operations: FrameLocalFileOperations
    private weak var context: FeatureContext?
    var isActive: Bool { work.isActive }
    init(_ context: FeatureContext, operations: FrameLocalFileOperations, access: FrameLocalAccessFeature) {
        self.context = context; self.operations = operations; work = FrameFeatureWork(context, access: access)
    }
    func cancel() { work.cancel() }
    func load(root: URL, rootID: UUID) async throws -> (photos: [PhotoItem], warnings: [String]) {
        let result = try await work.run(roots: [root]) { ArchiveService.load(root: root, rootID: rootID) }
        guard let context else { throw CancellationError() }
        try context.checkActive()
        return result
    }
    func apply(_ photos: [PhotoItem], root: URL, restoring: Bool,
               progress: @escaping @MainActor (Int) -> Void) async throws -> ArchiveBatchResult {
        guard let context else { throw CompositionError("Archive is unavailable.") }
        let operation = operations.archive
        return try await work.run(roots: [root]) {
            var result = ArchiveBatchResult()
            for photo in photos {
                if Task.isCancelled { break }
                do { try operation(photo, root, restoring) }
                catch { result.failures.append(FileActionFailure(photo: photo, reason: error.localizedDescription)) }
                result.processed += 1
                let count = result.processed
                await MainActor.run { if context.isActive { progress(count) } }
            }
            return result
        }
    }
}

@MainActor
final class FrameExportFeature {
    struct Plan: Sendable {
        let assets: AssetExportPlan
        let destination: URL
        var replacementNames: [String] { assets.replacementNames }
    }
    private let work: FrameFeatureWork
    private let operations: FrameLocalFileOperations
    var isActive: Bool { work.isActive }
    init(_ context: FeatureContext, operations: FrameLocalFileOperations, access: FrameLocalAccessFeature) {
        self.operations = operations; work = FrameFeatureWork(context, access: access)
    }
    func copy(_ photo: PhotoItem, root: URL?, to destination: URL, replacing: ExactCopyExporter.Replacement) async throws {
        let operation = operations.copy
        try await work.run(roots: [root, photo.url, destination].compactMap { $0 }, allowRetired: true) { try operation(photo.url, destination, replacing) }
    }
    func export(_ plan: Plan, root: URL?) async throws {
        let operation = operations.exportGroup
        let roots = [root, plan.destination].compactMap { $0 } + plan.assets.photo.exportMembers.map(\.url)
        try await work.run(roots: roots, allowRetired: true) { try operation(plan.assets) }
    }
    func plan(_ photo: PhotoItem, root: URL?, folder: URL) async throws -> Plan {
        let operation = operations.planExport
        let roots = [root, folder].compactMap { $0 } + photo.exportMembers.map(\.url)
        let plan = try await work.run(roots: roots, allowRetired: true) { try await operation(photo, folder) }
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
        // Keep the panel's original security-scoped URL across confirmation;
        // the pure filesystem plan contains a normalized destination.
        return Plan(assets: plan, destination: folder)
    }
}

// Local Trash with Undo, Archive and Restore, and export. Each owns its workers and joins a
// submitted filesystem transaction before it finishes unloading.

struct TrashFeature: Feature {
    @Constant var operations: FrameLocalFileOperations
    @Constant var history: TrashHistory
    @Need(FrameServices.LocalAccess.self) var access
    @Offer(FrameServices.Trash.self) var trash

    func run(_ context: FeatureContext) async throws {
        trash.set(FrameTrashFeature(context, operations: operations, history: history, access: access))
    }
}

struct ArchiveFeature: Feature {
    @Constant var operations: FrameLocalFileOperations
    @Need(FrameServices.LocalAccess.self) var access
    @Offer(FrameServices.Archive.self) var archive

    func run(_ context: FeatureContext) async throws {
        archive.set(FrameArchiveFeature(context, operations: operations, access: access))
    }
}

struct ExportFeature: Feature {
    @Constant var operations: FrameLocalFileOperations
    @Need(FrameServices.LocalAccess.self) var access
    @Offer(FrameServices.Export.self) var export

    func run(_ context: FeatureContext) async throws {
        export.set(FrameExportFeature(context, operations: operations, access: access))
    }
}

/// The shell's view of the file actions. Each property is present while its feature is loaded.
@MainActor
public final class FrameFileFeatures: ObservableObject {
    /// Session Trash history is data, not a feature: it outlives any reload of the Trash feature.
    let history = TrashHistory()
    let operations: FrameLocalFileOperations
    private var historyObservation: AnyCancellable?
    private var runtime: FeatureRuntime?
    var trash: FrameTrashFeature? { runtime?.service(FrameServices.Trash.self) }
    var archive: FrameArchiveFeature? { runtime?.service(FrameServices.Archive.self) }
    var exporter: FrameExportFeature? { runtime?.service(FrameServices.Export.self) }
    var remoteDelete: FrameRemoteDeleteFeature? { runtime?.service(FrameServices.RemoteDelete.self) }
    var remoteArchive: FrameRemoteArchiveFeature? { runtime?.service(FrameServices.RemoteArchive.self) }
    var remoteExporter: FrameRemoteExportFeature? { runtime?.service(FrameServices.RemoteExport.self) }
    public var canTrash: Bool { trash?.isActive == true }
    public var canArchive: Bool { archive?.isActive == true }
    public var canExport: Bool { exporter?.isActive == true }
    public var canRemoteDelete: Bool { remoteDelete?.isActive == true }
    public var canRemoteArchive: Bool { remoteArchive?.isActive == true }
    public var canRemoteExport: Bool { remoteExporter?.isActive == true }
    public var undoCount: Int { history.groups.count }
    public var undoAssetCount: Int { history.groups.last?.files.count ?? 0 }
    public var undoTitle: String { history.groups.last.map { "Undo Trash \($0.files.count) Assets" } ?? "Undo Trash" }
    public convenience init() { self.init(operations: FrameLocalFileOperations()) }
    init(operations: FrameLocalFileOperations) {
        self.operations = operations
        historyObservation = history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    func attach(_ runtime: FeatureRuntime) { self.runtime = runtime }
    public func cancel() { trash?.cancel(); archive?.cancel(); remoteDelete?.cancel(); remoteArchive?.cancel() }
}
