import BridgeProtocol
import Composition
import XCTest
@testable import FrameKit

struct FixtureRemoteLibrary: RemoteLibraryServing {
    var readCatalog: @Sendable () async throws -> BridgeResponse = { BridgeResponse() }
    var loader: RemoteFolderIndex.Loader = { _, _ in
        XCTFail("Unexpected fixture listing"); throw BridgeError("Fixture listing unavailable")
    }
    var remember: @Sendable (BridgeSource, String) async throws -> Void = { _, _ in XCTFail("Frame changed RelayBar history") }
    func catalog() async throws -> BridgeResponse { try await readCatalog() }
    func list(source: BridgeSource, path: String) async throws -> ScanResult { try await loader(source, path) }
    func handoff(_ nonce: UUID) async throws -> BridgeHandoff { XCTFail("Unexpected fixture handoff"); throw BridgeError("Fixture handoff unavailable") }
    func rememberOpen(source: BridgeSource, path: String) async throws { try await remember(source, path) }
}

extension FrameComposition {
    /// A composition whose remote session is a fixture offering only the given capabilities.
    @MainActor
    static func fixture(preferencesURL: URL? = nil, mediaFeatures: FrameMediaFeatures? = nil,
                        library: (any RemoteLibraryServing)? = nil, files: (any RemoteFileReading)? = nil,
                        previews: (any RemotePreviewServing)? = nil, actions: (any RemoteActionServing)? = nil) -> FrameComposition {
        FrameComposition(preferencesURL: preferencesURL, mediaFeatures: mediaFeatures,
                         remoteSession: FixedRemoteSession(PartialRemoteSession(library: library, files: files, previews: previews, actions: actions)))
    }
}

@MainActor
func makeRemoteStore(defaults: UserDefaults = .standard,
                     preferencesURL: URL? = nil,
                     remoteCatalogLoader: @escaping @Sendable () async throws -> BridgeResponse = { BridgeResponse() },
                     remoteFolderLoader: @escaping RemoteFolderIndex.Loader = { _, _ in throw BridgeError("Fixture listing unavailable") },
                     remoteOpenRecorder: @escaping @Sendable (BridgeSource, String) async throws -> Void = { _, _ in XCTFail("Frame changed RelayBar history") },
                     actions: FixtureRemoteActions = .init()) -> LibraryStore {
    let library = FixtureRemoteLibrary(readCatalog: remoteCatalogLoader, loader: remoteFolderLoader, remember: remoteOpenRecorder)
    let composition = FrameComposition.fixture(preferencesURL: preferencesURL, library: library, actions: actions)
    return LibraryStore(defaults: defaults, previews: composition)
}

struct FixtureRemoteActions: RemoteActionServing {
    var mutation: @Sendable (PhotoItem, String, String) async throws -> UUID? = { _, _, _ in
        XCTFail("Unexpected fixture mutation"); throw BridgeError("Fixture mutation unavailable")
    }
    var deletion: @Sendable ([PhotoItem], String) async -> [FileActionFailure] = { photos, _ in
        XCTFail("Unexpected fixture deletion"); return photos.map { FileActionFailure(photo: $0, reason: "Fixture deletion unavailable") }
    }
    var archive: @Sendable (BridgeSource, String) async throws -> [PhotoItem] = { _, _ in
        XCTFail("Unexpected fixture archive listing"); throw BridgeError("Fixture archive unavailable")
    }
    func mutate(_ photo: PhotoItem, action: String, root: String) async throws -> UUID? { try await mutation(photo, action, root) }
    func delete(_ photos: [PhotoItem], root: String) async -> [FileActionFailure] { await deletion(photos, root) }
    func archivedAssets(source: BridgeSource, root: String) async throws -> [PhotoItem] { try await archive(source, root) }
    @MainActor func composition() -> FrameComposition { .fixture(actions: self) }
}
