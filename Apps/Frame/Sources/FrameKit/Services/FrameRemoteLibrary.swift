import BridgeProtocol
import Composition
import Foundation

@MainActor
final class FrameRemoteLibraryFeature {
    private weak var context: FeatureContext?
    private let session: any RemoteAssetServing
    private var indexes: [UUID: RemoteFolderIndex] = [:]
    private var closed = false
    var isActive: Bool { !closed && context?.isActive == true }
    init(_ context: FeatureContext, session: any RemoteAssetServing) {
        self.context = context; self.session = session
    }
    func catalog() async throws -> BridgeResponse {
        guard let context, !closed else { throw CompositionError("Remote library is unavailable.") }
        let session = session
        return try await context.perform { try await session.catalog() }
    }
    func owns(_ index: RemoteFolderIndex) -> Bool { indexes.values.contains { $0 === index } && !index.isStopped }
    func scan(_ index: RemoteFolderIndex, path: String, publish: @escaping @MainActor (RemoteScanSnapshot) -> Void) async throws {
        guard let context, !closed, owns(index) else { throw CompositionError("Remote folder is no longer active.") }
        try await context.perform {
            try await RemoteSubfolderScan.run(index: index, path: path) { snapshot in
                guard context.isActive else { return }
                publish(snapshot)
            }
        }
    }
    func makeIndex(source: BridgeSource, path: String) throws -> RemoteFolderIndex {
        guard let context, !closed else { throw CompositionError("Remote library is unavailable.") }
        try context.checkActive()
        let session = session
        let index = RemoteFolderIndex(source: source, path: path, authorize: { [weak context] in
            guard let context else { throw CancellationError() }
            try context.checkActive()
        }, loader: { [weak context] source, path in
            guard let context else { throw CancellationError() }
            try await MainActor.run { try context.checkActive() }
            let value = try await session.list(source: source, path: path)
            try await MainActor.run { try context.checkActive() }
            return value
        })
        let id = UUID()
        indexes[id] = index
        index.didShutdown = { [weak self] in self?.indexes.removeValue(forKey: id) }
        return index
    }
    func stop() {
        closed = true
        for index in indexes.values { index.stop() }
    }
    func shutdown() async {
        stop()
        let pending = Array(indexes.values)
        for index in pending { await index.shutdown() }
        indexes.removeAll()
    }
}

/// Catalog calls, folder indexes and recursive scans against the session.
struct RemoteLibraryFeature: Feature {
    @Need(FrameServices.RelaySession.self) var session
    @Offer(FrameServices.RemoteLibrary.self) var library

    func run(_ context: FeatureContext) async throws {
        let feature = FrameRemoteLibraryFeature(context, session: session)
        try context.effect("remote library", cancel: { feature.stop() }) { await feature.shutdown() }
        library.set(feature)
    }
}

/// The shell's view of the remote library: present while the session is.
@MainActor
public final class FrameRemoteLibrary {
    private var port: ServicePort<FrameRemoteLibraryFeature>?
    func attach(_ runtime: FeatureRuntime) { port = runtime.port(FrameServices.RemoteLibrary.self) }
    var feature: FrameRemoteLibraryFeature? { port?.value }
    public var isAvailable: Bool { feature?.isActive == true }
}
