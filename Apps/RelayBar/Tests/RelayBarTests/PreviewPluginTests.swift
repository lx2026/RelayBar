import AppKit
import Composition
import PreviewSupport
import XCTest
@testable import RelayBar

@MainActor
final class PreviewPluginTests: XCTestCase {
    private let registry = RemotePreviewPlugins.Registry()
    private let scope = EffectScope()

    /// Registers one format the way a standalone model does, so closing it disables that format alone.
    private func register(_ kind: String, maximumBytes: Int64? = nil,
                          _ service: PreviewFixtureService) throws -> PreviewRegistration {
        let current = try RemotePreviewPlugins.descriptor(kind, maximumBytes: maximumBytes)
        return try registry.register(current, isActive: { [scope] in scope.isOpen },
            render: RemotePreviewPlugins.renderer(current, service: service, decoders: RelayPreviewDecoders(
                image: { _ in NSImage(size: NSSize(width: 1, height: 1)) },
                markdown: { _ in throw RemoteFileError.invalidMarkdownEncoding },
                json: { _ in throw RemoteFileError.invalidJSONEncoding }, video: { _ in }), scope: scope))
    }
    private func open(_ name: String, size: Int64? = 8) async throws -> PreviewSession<RelayPreviewContent> {
        try await registry.open(filename: name, bytes: nil, request: RelayPreviewRequest(
            entry: .init(name: name, path: "/fixture/" + name, kind: .file, size: size, modificationText: "0"),
            server: RemoteServer(id: UUID(), name: "Fixture", sshHost: "fixture.invalid", additionalArguments: []),
            root: "/fixture", progress: { _ in }, preparingVideo: {}, navigate: { _ in }, navigationError: { _ in }))
    }

    func testDisablingImageDisposesItsFileAndPreservesVideo() async throws {
        let service = PreviewFixtureService()
        let imageFormat = try register("image", service)
        let videoFormat = try register("video", service)
        let image = try await open("image.png")
        let video = try await open("video.mp4")
        let folders = await service.folders
        XCTAssertEqual(folders.count, 2)
        await imageFormat.close()
        XCTAssertTrue(image.isClosed); XCTAssertFalse(video.isClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folders[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders[1].path))
        let reenabledImageFormat = try register("image", service)
        let reopened = try await open("image.png")
        XCTAssertNotNil(reopened.content.image)
        await reenabledImageFormat.close()
        await videoFormat.close()
        await scope.dispose()
        let all = await service.folders
        XCTAssertTrue(all.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    /// The standalone owner a model builds for itself: stopping it closes every result and removes every file.
    func testStoppingAllFormatsClosesEveryPreviewAndRemovesItsFiles() async throws {
        let service = PreviewFixtureService()
        let previews = try RemotePreviews.allFormats(service: service, decoders: RelayPreviewDecoders(
            image: { _ in NSImage(size: NSSize(width: 1, height: 1)) },
            markdown: { _ in throw RemoteFileError.invalidMarkdownEncoding },
            json: { _ in throw RemoteFileError.invalidJSONEncoding }, video: { _ in }))
        func request(_ name: String) -> RelayPreviewRequest {
            RelayPreviewRequest(
                entry: .init(name: name, path: "/fixture/" + name, kind: .file, size: 8, modificationText: "0"),
                server: RemoteServer(id: UUID(), name: "Fixture", sshHost: "fixture.invalid", additionalArguments: []),
                root: "/fixture", progress: { _ in }, preparingVideo: {}, navigate: { _ in }, navigationError: { _ in })
        }
        let image = try await previews.open(request("image.png"))
        let video = try await previews.open(request("video.mp4"))
        let folders = await service.folders
        XCTAssertEqual(folders.count, 2)
        await previews.stop()
        XCTAssertTrue(image.isClosed)
        XCTAssertTrue(video.isClosed)
        XCTAssertTrue(folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        do {
            _ = try await previews.open(request("image.png"))
            XCTFail("A stopped owner still opened a preview")
        } catch {}
        let afterStop = await service.folders
        XCTAssertTrue(afterStop.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testConfiguredLimitRejectsMetadataAndActualDownloadedBytes() async throws {
        let service = PreviewFixtureService()
        let imageFormat = try register("image", maximumBytes: 4, service)
        do { _ = try await open("image.png"); XCTFail("Metadata limit ignored") }
        catch { XCTAssertEqual(error as? RemoteFileError, .previewTooLarge) }
        let before = await service.folders
        XCTAssertTrue(before.isEmpty)
        do { _ = try await open("image.png", size: nil); XCTFail("Actual size limit ignored") }
        catch { XCTAssertEqual(error as? RemoteFileError, .previewTooLarge) }
        let after = await service.folders
        XCTAssertEqual(after.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: after[0].path))
        await imageFormat.close()
        await scope.dispose()
    }
}

private actor PreviewFixtureService: RemoteFileServing {
    var folders: [URL] = []
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] { [] }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {}
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPreviewFixture-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let file = folder.appendingPathComponent(entry.name)
        try Data(repeating: 42, count: 8).write(to: file)
        return file
    }
}
