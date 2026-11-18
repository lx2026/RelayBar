import AppKit
import BridgeProtocol
import Combine
import Composition

/// What a media reader may ask of the session. Every call, including a cache read, is rejected once
/// the owning feature has been withdrawn, before and after it runs.
@MainActor
final class MediaRemoteAccess: RemoteFileReading, RemotePreviewServing {
    private weak var context: FeatureContext?
    private let session: any RemoteAssetServing
    init(_ context: FeatureContext, session: any RemoteAssetServing) { self.context = context; self.session = session }
    // Inline, not an owned run: every caller already runs inside its feature's owned work.
    private func use<Value>(_ body: (any RemoteAssetServing) async throws -> Value) async throws -> Value {
        guard let context else { throw CancellationError() }
        try context.checkActive()
        let value = try await body(session)
        try context.checkActive()
        return value
    }
    func resolve(_ photo: PhotoItem, includeCompanions: Bool, allowVideo: Bool, priority: Int) async throws -> PhotoItem {
        try await use { try await $0.resolve(photo, includeCompanions: includeCompanions, allowVideo: allowVideo, priority: priority) }
    }
    func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry] {
        try await use { try await $0.documentStats(source: source, root: root, paths: paths) }
    }
    func cachedMedia(_ photo: PhotoItem) async -> PhotoItem? {
        try? await use { await $0.cachedMedia(photo) }
    }
    func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText] {
        (try? await use { await $0.companionText(photo) }) ?? []
    }
    func pin(_ photo: PhotoItem?) async {
        try? await use { await $0.pin(photo) }
    }
    func preview(_ photo: PhotoItem, pixels: Int, priority: Int) async throws -> BridgeAssetResult {
        try await use { try await $0.preview(photo, pixels: pixels, priority: priority) }
    }
}

struct FrameMediaOperations: Sendable {
    var image: @Sendable (PhotoItem, Int, Int, ImageRepository) async -> CGImage? = {
        await $3.image(for: $0, maxPixelSize: $1, priority: $2)
    }
    var metadata: @Sendable (PhotoItem, (any RemoteFileReading)?, (any RemotePreviewServing)?, VideoMetadataReader) async -> ImageMetadata = {
        await ImageMetadataReader.read(photo: $0, remoteClient: $1, remotePreview: $2, videoMetadata: $3)
    }
}

@MainActor
final class FrameThumbnailsFeature {
    private weak var context: FeatureContext?
    private let work: FrameFeatureWork
    private let repository: ImageRepository
    private let operations: FrameMediaOperations
    private let remote: Bool
    var isActive: Bool { context?.isActive == true }
    init(_ context: FeatureContext, source: FrameMediaSource, operations: FrameMediaOperations) {
        self.context = context; remote = source.isRemote; self.operations = operations
        work = FrameFeatureWork(context, access: source.access)
        repository = ImageRepository(remoteClient: source.session.map { MediaRemoteAccess(context, session: $0) })
    }
    private func authorize() throws {
        guard let context else { throw CancellationError() }
        try context.checkActive()
    }
    func image(_ photo: PhotoItem, pixels: Int, priority: Int = 0) async throws -> CGImage? {
        try authorize()
        guard (photo.remote != nil) == remote else { throw CompositionError("Thumbnail location changed.") }
        let operation = operations.image, repository = repository
        let value = try await work.run(roots: remote ? [] : [photo.url], rootID: photo.rootID) { await operation(photo, pixels, priority, repository) }
        try Task.checkCancellation(); try authorize()
        return value
    }
    func invalidate() async { await repository.invalidate() }
    func cancel() { work.cancel() }
}

@MainActor
final class FrameMetadataFeature {
    private weak var context: FeatureContext?
    private let work: FrameFeatureWork
    private let reader: VideoMetadataReader
    private let client: (any RemoteFileReading)?
    private let previewClient: (any RemotePreviewServing)?
    private let operations: FrameMediaOperations
    private let remote: Bool
    var isActive: Bool { context?.isActive == true }
    /// Identifies this instance to the UI, which reloads when a replacement appears.
    var generation: UInt64? { isActive ? context?.generation : nil }
    init(_ context: FeatureContext, source: FrameMediaSource, helper: Bool = false, operations: FrameMediaOperations) {
        self.context = context; remote = source.isRemote; self.operations = operations
        work = FrameFeatureWork(context, access: source.access)
        let client = source.session.map { MediaRemoteAccess(context, session: $0) }
        previewClient = helper ? client : nil
        self.client = client; reader = VideoMetadataReader(remoteClient: client)
    }
    private func authorize() throws {
        guard let context else { throw CancellationError() }
        try context.checkActive()
    }
    private func roots(_ photo: PhotoItem) throws -> [URL] {
        try authorize()
        guard (photo.remote != nil) == remote else { throw CompositionError("Metadata location changed.") }
        return remote ? [] : photo.fileMembers.map(\.url)
    }
    func read(_ photo: PhotoItem) async throws -> ImageMetadata {
        let roots = try roots(photo), operation = operations.metadata, reader = reader, client = client, preview = previewClient
        let value = try await work.run(roots: roots, rootID: photo.rootID) { await operation(photo, client, preview, reader) }
        try Task.checkCancellation(); try authorize()
        return value
    }
    func videoInfo(_ photo: PhotoItem) async throws -> VideoInfo {
        let roots = try roots(photo), reader = reader
        let value = try await work.run(roots: roots, rootID: photo.rootID) { await reader.info(for: photo) }
        try Task.checkCancellation(); try authorize()
        return value
    }
    func invalidate() async { await reader.invalidate() }
    func cancel() { work.cancel() }
}

@MainActor
final class FramePlaybackFeature {
    private weak var context: FeatureContext?
    private let access: FrameLocalAccessFeature
    private let metadata: FrameMetadataFeature
    let controller: PlaybackController
    init(_ context: FeatureContext, controller: PlaybackController, access: FrameLocalAccessFeature, metadata: FrameMetadataFeature) {
        self.context = context; self.controller = controller; self.access = access; self.metadata = metadata
    }
    func prepare(_ photo: PhotoItem, downloadOriginal: Bool,
                 resolve: @escaping @MainActor (PhotoItem) async throws -> PhotoItem) throws {
        guard let context else { throw CancellationError() }
        try context.checkActive()
        let lease = photo.remote == nil ? try access.acquire([photo.url], rootID: photo.rootID) : nil
        let metadata = metadata
        controller.prepare(photo, downloadOriginal: downloadOriginal, release: { lease?.release() }) { [weak context] photo in
            guard let context else { throw CancellationError() }
            try context.checkActive()
            let local = try await resolve(photo)
            try context.checkActive()
            let info = try await metadata.videoInfo(local)
            try context.checkActive()
            return (local, info)
        }
    }
    func stop() { controller.clear() }
    func finishStopping() async { await controller.finishStopping() }
}

@MainActor
final class FrameOriginalsFeature {
    private weak var context: FeatureContext?
    private let session: any RemoteAssetServing
    var isActive: Bool { context?.isActive == true }
    init(_ context: FeatureContext, session: any RemoteAssetServing) {
        self.context = context; self.session = session
    }
    func resolve(_ photo: PhotoItem) async throws -> PhotoItem {
        guard let context else { throw CancellationError() }
        let session = session
        return try await context.perform { try await session.resolve(photo, allowVideo: true) }
    }
    func pin(_ photo: PhotoItem?) async throws {
        guard let context else { throw CancellationError() }
        let session = session
        try await context.perform { await session.pin(photo) }
    }
}

// Thumbnails and metadata are written once against the realm's media source and mounted in both
// worlds. The player is shared: it follows the selection, local or remote.

struct ThumbnailsFeature: Feature {
    @Constant var operations: FrameMediaOperations
    @Need(FrameServices.MediaSource.self) var source
    @Offer(FrameServices.Thumbnails.self) var thumbnails

    func run(_ context: FeatureContext) async throws {
        let feature = FrameThumbnailsFeature(context, source: source, operations: operations)
        try context.effect("thumbnails", cancel: { feature.cancel() }) { await feature.invalidate() }
        thumbnails.set(feature)
    }
}

struct MetadataFeature: Feature {
    @Constant var operations: FrameMediaOperations
    @Need(FrameServices.MediaSource.self) var source
    @Offer(FrameServices.Metadata.self) var metadata

    func run(_ context: FeatureContext) async throws {
        let feature = FrameMetadataFeature(context, source: source, operations: operations)
        try context.effect("metadata", cancel: { feature.cancel() }) { await feature.invalidate() }
        metadata.set(feature)
    }
}

/// Remote image metadata read through RelayBar's helper. Optional: without it video metadata still works.
struct HelperMetadataFeature: Feature {
    @Constant var operations: FrameMediaOperations
    @Need(FrameServices.MediaSource.self) var source
    @Offer(FrameServices.HelperMetadata.self) var metadata

    func run(_ context: FeatureContext) async throws {
        let feature = FrameMetadataFeature(context, source: source, helper: true, operations: operations)
        try context.effect("helper metadata", cancel: { feature.cancel() }) { await feature.invalidate() }
        metadata.set(feature)
    }
}

struct OriginalsFeature: Feature {
    @Need(FrameServices.RelaySession.self) var session
    @Offer(FrameServices.Originals.self) var originals

    func run(_ context: FeatureContext) async throws {
        originals.set(FrameOriginalsFeature(context, session: session))
    }
}

struct PlaybackFeature: Feature {
    @Constant var controller: PlaybackController
    @Need(FrameServices.LocalAccess.self) var access
    @Need(FrameServices.Metadata.self) var metadata
    @Offer(FrameServices.Playback.self) var playback

    func run(_ context: FeatureContext) async throws {
        let feature = FramePlaybackFeature(context, controller: controller, access: access, metadata: metadata)
        try context.effect("player", cancel: { feature.stop() }) { await feature.finishStopping() }
        playback.set(feature)
    }
}

/// The shell's view of the media readers in both worlds.
@MainActor
public final class FrameMediaFeatures {
    let operations: FrameMediaOperations
    private var runtime: FeatureRuntime?
    var thumbnails: FrameThumbnailsFeature? { runtime?.service(FrameServices.Thumbnails.self) }
    var remoteThumbnails: FrameThumbnailsFeature? { runtime?.service(FrameServices.Thumbnails.self, realm: "remote") }
    var metadata: FrameMetadataFeature? { runtime?.service(FrameServices.Metadata.self) }
    var remoteMetadata: FrameMetadataFeature? { runtime?.service(FrameServices.Metadata.self, realm: "remote") }
    var helperMetadata: FrameMetadataFeature? { runtime?.service(FrameServices.HelperMetadata.self) }
    var originals: FrameOriginalsFeature? { runtime?.service(FrameServices.Originals.self) }
    public var canResolveOriginal: Bool { originals?.isActive == true }
    public init() { operations = FrameMediaOperations() }
    init(operations: FrameMediaOperations) { self.operations = operations }
    func attach(_ runtime: FeatureRuntime) { self.runtime = runtime }
    private func metadataFeature(for photo: PhotoItem) -> FrameMetadataFeature? {
        if photo.remote == nil { return metadata }
        if photo.format.isImage, let helperMetadata, helperMetadata.isActive { return helperMetadata }
        return remoteMetadata
    }
    func metadataGeneration(for photo: PhotoItem) -> String? {
        guard let feature = metadataFeature(for: photo), let generation = feature.generation else { return nil }
        return "\(ObjectIdentifier(feature)):\(generation)"
    }
    public func readMetadata(_ photo: PhotoItem) async throws -> ImageMetadata {
        guard let feature = metadataFeature(for: photo) else { throw CompositionError("Media information is unavailable.") }
        return try await feature.read(photo)
    }
    public func videoInfo(_ photo: PhotoItem) async throws -> VideoInfo {
        guard let feature = photo.remote == nil ? metadata : remoteMetadata else { throw CompositionError("Media information is unavailable.") }
        return try await feature.videoInfo(photo)
    }
    public func resolveOriginal(_ photo: PhotoItem) async throws -> PhotoItem {
        guard let originals else { throw CompositionError("Original download is unavailable.") }
        return try await originals.resolve(photo)
    }
    public func pin(_ photo: PhotoItem?) async { try? await originals?.pin(photo) }
    public func invalidate() async {
        await thumbnails?.invalidate(); await remoteThumbnails?.invalidate()
        await metadata?.invalidate(); await remoteMetadata?.invalidate()
        await helperMetadata?.invalidate()
    }
}
