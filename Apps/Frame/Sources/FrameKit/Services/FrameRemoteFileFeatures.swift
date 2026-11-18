import BridgeProtocol
import Composition
import Foundation

struct RemoteMutationResult: Sendable {
    var removed: Set<PhotoItem.ID> = []
    var failures: [FileActionFailure] = []
    var processed = 0
}

@MainActor
final class FrameRemoteDeleteFeature {
    private weak var context: FeatureContext?
    private let session: any RemoteAssetServing
    private let work: FrameFeatureWork
    var isActive: Bool { work.isActive }
    init(_ context: FeatureContext, session: any RemoteAssetServing) {
        self.context = context; self.session = session; work = FrameFeatureWork(context, access: nil)
    }
    func cancel() { work.cancel() }
    func delete(_ photos: [PhotoItem], root: String) async throws -> RemoteMutationResult {
        guard let context else { throw CompositionError("Remote Delete is unavailable.") }
        let session = session
        return try await work.run {
            try context.checkActive()
            let failures = await session.delete(photos, root: root)
            // Preserve confirmed per-item outcomes, including when cancellation arrived after submission.
            // Uncertain results remain failures from the transport; they are never replayed here.
            return RemoteMutationResult(removed: Set(photos.map(\.id)).subtracting(failures.map { $0.photo.id }),
                                        failures: failures, processed: photos.count)
        }
    }
}

@MainActor
final class FrameRemoteArchiveFeature {
    private weak var context: FeatureContext?
    private let session: any RemoteAssetServing
    private let work: FrameFeatureWork
    var isActive: Bool { work.isActive }
    init(_ context: FeatureContext, session: any RemoteAssetServing) {
        self.context = context; self.session = session; work = FrameFeatureWork(context, access: nil)
    }
    func cancel() { work.cancel() }
    func apply(_ photos: [PhotoItem], root: String, restoring: Bool,
               progress: @escaping @MainActor (Int) -> Void) async throws -> RemoteMutationResult {
        guard let context else { throw CompositionError("Remote Archive is unavailable.") }
        let session = session
        return try await work.run {
            try context.checkActive()
            var result = RemoteMutationResult()
            for photo in photos {
                guard !Task.isCancelled, context.isActive else { break }
                do {
                    _ = try await session.mutate(photo, action: restoring ? "restore" : "archive", root: root)
                    result.removed.insert(photo.id)
                } catch { result.failures.append(FileActionFailure(photo: photo, reason: error.localizedDescription)) }
                result.processed += 1
                if context.isActive { progress(result.processed) }
            }
            return result
        }
    }
    func load(source: BridgeSource, root: String) async throws -> [PhotoItem] {
        guard let context else { throw CompositionError("Remote Archive is unavailable.") }
        let session = session
        // Through `work`, so Cancel on a file operation also stops a listing in progress.
        return try await work.run {
            try context.checkActive()
            let result = try await session.archivedAssets(source: source, root: root)
            try context.checkActive()
            return result
        }
    }
}

@MainActor
final class FrameRemoteExportFeature {
    private weak var context: FeatureContext?
    private let session: any RemoteAssetServing
    var isActive: Bool { context?.isActive == true }
    init(_ context: FeatureContext, session: any RemoteAssetServing) {
        self.context = context; self.session = session
    }
    func resolve(_ photo: PhotoItem) async throws -> PhotoItem {
        guard let context else { throw CompositionError("Remote export is unavailable.") }
        let session = session
        return try await context.perform { try await session.resolve(photo, includeCompanions: true, allowVideo: true) }
    }
}

// The remote file actions. Each wraps session calls; none needs its local counterpart.

struct RemoteDeleteFeature: Feature {
    @Need(FrameServices.RelaySession.self) var session
    @Offer(FrameServices.RemoteDelete.self) var delete

    func run(_ context: FeatureContext) async throws {
        let feature = FrameRemoteDeleteFeature(context, session: session)
        try context.effect("remote delete", cancel: { feature.cancel() }) {}
        delete.set(feature)
    }
}

struct RemoteArchiveFeature: Feature {
    @Need(FrameServices.RelaySession.self) var session
    @Offer(FrameServices.RemoteArchive.self) var archive

    func run(_ context: FeatureContext) async throws {
        let feature = FrameRemoteArchiveFeature(context, session: session)
        try context.effect("remote archive", cancel: { feature.cancel() }) {}
        archive.set(feature)
    }
}

struct RemoteExportFeature: Feature {
    @Need(FrameServices.RelaySession.self) var session
    @Offer(FrameServices.RemoteExport.self) var export

    func run(_ context: FeatureContext) async throws { export.set(FrameRemoteExportFeature(context, session: session)) }
}
