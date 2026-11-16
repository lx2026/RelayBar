import BridgeProtocol
import Foundation

public protocol RemoteLibraryServing: Sendable {
    func catalog() async throws -> BridgeResponse
    func handoff(_ nonce: UUID) async throws -> BridgeHandoff
    func list(source: BridgeSource, path: String) async throws -> ScanResult
    func rememberOpen(source: BridgeSource, path: String) async throws
}

public protocol RemoteFileReading: Sendable {
    func resolve(_ photo: PhotoItem, includeCompanions: Bool, allowVideo: Bool, priority: Int) async throws -> PhotoItem
    func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry]
    func cachedMedia(_ photo: PhotoItem) async -> PhotoItem?
    func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText]
    func pin(_ photo: PhotoItem?) async
}

public extension RemoteFileReading {
    func resolve(_ photo: PhotoItem, includeCompanions: Bool = false, allowVideo: Bool = false) async throws -> PhotoItem {
        try await resolve(photo, includeCompanions: includeCompanions, allowVideo: allowVideo, priority: 0)
    }
}

public protocol RemotePreviewServing: Sendable {
    func preview(_ photo: PhotoItem, pixels: Int, priority: Int) async throws -> BridgeAssetResult
}
public extension RemotePreviewServing {
    func preview(_ photo: PhotoItem, pixels: Int) async throws -> BridgeAssetResult {
        try await preview(photo, pixels: pixels, priority: 0)
    }
}

public protocol RemoteActionServing: Sendable {
    func mutate(_ photo: PhotoItem, action: String, root: String) async throws -> UUID?
    func delete(_ photos: [PhotoItem], root: String) async -> [FileActionFailure]
    func archivedAssets(source: BridgeSource, root: String) async throws -> [PhotoItem]
}

public protocol RemoteAssetServing: RemoteLibraryServing, RemoteFileReading, RemotePreviewServing, RemoteActionServing {}
