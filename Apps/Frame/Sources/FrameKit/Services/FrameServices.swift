import BridgeProtocol
import Composition
import Foundation
import PreviewSupport

/// The services Frame's features exchange. Local features live at the root of the tree. The same
/// media features are mounted again inside the `remote` realm, which isolates the keys marked below,
/// so one definition serves both worlds.
enum FrameServices {
    /// The authenticated RelayBar session. Filled and cleared by the link while it runs.
    enum RelaySession: ServiceKey { typealias Value = any RemoteAssetServing }
    /// The shell's owned access to the session: calls made through it are joined before the session is released.
    enum RemoteAccess: ServiceKey { typealias Value = FrameRemoteAccess }
    enum LocalAccess: ServiceKey { typealias Value = FrameLocalAccessFeature }

    // Isolated per realm.
    enum MediaSource: ServiceKey { typealias Value = FrameMediaSource }
    enum Thumbnails: ServiceKey { typealias Value = FrameThumbnailsFeature }
    enum Metadata: ServiceKey { typealias Value = FrameMetadataFeature }
    enum Previews: ServiceKey { typealias Value = FrameComposition.Registry }
    enum PlaybackPreviews: ServiceKey { typealias Value = FrameComposition.Registry }
    /// Prompt Search over this realm's media, present while its plugin is on.
    enum PromptSearch: ServiceKey { typealias Value = FramePromptSearchFeature }
    static let isolatedInRemoteRealm: [any ServiceKey.Type] = [
        MediaSource.self, Thumbnails.self, Metadata.self, Previews.self, PlaybackPreviews.self, PromptSearch.self
    ]

    // Shared by both worlds: one player and one document renderer follow the selection.
    enum Playback: ServiceKey { typealias Value = FramePlaybackFeature }
    enum Documents: ServiceKey { typealias Value = DocumentRendererOwner }

    // Local only.
    enum Catalog: ServiceKey { typealias Value = FrameCatalogFeature }
    enum Favorites: ServiceKey { typealias Value = FrameFavoritesFeature }
    enum Scanning: ServiceKey { typealias Value = FrameScanningFeature }
    enum Trash: ServiceKey { typealias Value = FrameTrashFeature }
    enum Archive: ServiceKey { typealias Value = FrameArchiveFeature }
    enum Export: ServiceKey { typealias Value = FrameExportFeature }

    // Remote only.
    enum RemoteLibrary: ServiceKey { typealias Value = FrameRemoteLibraryFeature }
    enum HelperMetadata: ServiceKey { typealias Value = FrameMetadataFeature }
    enum Originals: ServiceKey { typealias Value = FrameOriginalsFeature }
    enum RemoteDelete: ServiceKey { typealias Value = FrameRemoteDeleteFeature }
    enum RemoteArchive: ServiceKey { typealias Value = FrameRemoteArchiveFeature }
    enum RemoteExport: ServiceKey { typealias Value = FrameRemoteExportFeature }
}

/// Where a realm's media comes from. A media feature is written once against this.
enum FrameMediaSource {
    case local(FrameLocalAccessFeature)
    case remote(any RemoteAssetServing)

    var isRemote: Bool { if case .remote = self { return true }; return false }
    var access: FrameLocalAccessFeature? { if case .local(let access) = self { return access }; return nil }
    var session: (any RemoteAssetServing)? { if case .remote(let session) = self { return session }; return nil }
}

/// A session assembled from whichever capabilities a fixture or the verification bundle supplies.
/// A missing capability reports that it is unavailable.
public struct PartialRemoteSession: RemoteAssetServing {
    private let library: (any RemoteLibraryServing)?
    private let files: (any RemoteFileReading)?
    private let previews: (any RemotePreviewServing)?
    private let actions: (any RemoteActionServing)?
    public init(library: (any RemoteLibraryServing)? = nil, files: (any RemoteFileReading)? = nil,
                previews: (any RemotePreviewServing)? = nil, actions: (any RemoteActionServing)? = nil) {
        self.library = library; self.files = files; self.previews = previews; self.actions = actions
    }
    private func missing(_ what: String) -> BridgeError { BridgeError("\(what) is unavailable.") }

    public func catalog() async throws -> BridgeResponse {
        guard let library else { throw missing("Remote library") }; return try await library.catalog()
    }
    public func handoff(_ nonce: UUID) async throws -> BridgeHandoff {
        guard let library else { throw missing("Remote library") }; return try await library.handoff(nonce)
    }
    public func list(source: BridgeSource, path: String) async throws -> ScanResult {
        guard let library else { throw missing("Remote library") }; return try await library.list(source: source, path: path)
    }
    public func rememberOpen(source: BridgeSource, path: String) async throws {
        guard let library else { throw missing("Remote library") }; try await library.rememberOpen(source: source, path: path)
    }
    public func resolve(_ photo: PhotoItem, includeCompanions: Bool, allowVideo: Bool, priority: Int) async throws -> PhotoItem {
        guard let files else { throw missing("Remote file access") }
        return try await files.resolve(photo, includeCompanions: includeCompanions, allowVideo: allowVideo, priority: priority)
    }
    public func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry] {
        guard let files else { throw missing("Remote file access") }
        return try await files.documentStats(source: source, root: root, paths: paths)
    }
    public func cachedMedia(_ photo: PhotoItem) async -> PhotoItem? { await files?.cachedMedia(photo) }
    public func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText] { await files?.companionText(photo) ?? [] }
    public func pin(_ photo: PhotoItem?) async { await files?.pin(photo) }
    public func preview(_ photo: PhotoItem, pixels: Int, priority: Int) async throws -> BridgeAssetResult {
        guard let previews else { throw missing("Remote preview") }
        return try await previews.preview(photo, pixels: pixels, priority: priority)
    }
    public func mutate(_ photo: PhotoItem, action: String, root: String) async throws -> UUID? {
        guard let actions else { throw missing("Remote action") }
        return try await actions.mutate(photo, action: action, root: root)
    }
    public func delete(_ photos: [PhotoItem], root: String) async -> [FileActionFailure] {
        guard let actions else { return photos.map { FileActionFailure(photo: $0, reason: "Remote action is unavailable.") } }
        return await actions.delete(photos, root: root)
    }
    public func archivedAssets(source: BridgeSource, root: String) async throws -> [PhotoItem] {
        guard let actions else { throw missing("Remote action") }
        return try await actions.archivedAssets(source: source, root: root)
    }
}
