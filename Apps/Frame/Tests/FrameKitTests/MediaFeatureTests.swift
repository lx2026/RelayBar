import AppKit
import BridgeProtocol
import Composition
import XCTest
@testable import FrameKit

@MainActor
final class MediaFeatureTests: XCTestCase {
    private func photo(_ name: String = "landscape.mp4") throws -> PhotoItem {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        return try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: UUID()).photos.first { $0.name == name })
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Media lifecycle did not reach the expected state")
        throw CancellationError()
    }
    private func remote(_ local: PhotoItem) -> PhotoItem {
        var photo = local
        photo.remote = RemoteAssetReference(source: BridgeSource(id: String(repeating: "a", count: 64), name: "Media fixture"),
            listingID: UUID(), entry: BridgeEntry(name: local.name, path: "/media/" + local.name, directory: false, size: local.fileSize, modified: "1"))
        return photo
    }

    func testRemoteVideoSurvivesHelperReplacementAndThumbnailWithdrawal() async throws {
        let local = try photo(), video = remote(local), gate = mediaGate()
        addTeardownBlock { await gate.releaseAll() }
        let image = remote(PhotoItem(id: "image", rootID: UUID(), url: URL(fileURLWithPath: "/media/image.png"),
            relativePath: "image.png", folderRelativePath: "", name: "image.png", format: .png, fileSize: 100,
            createdAt: nil, modifiedAt: nil, fileIdentifier: nil))
        let provider = MediaRemoteFixture(download: { _ in local }, cached: local)
        // The helper-backed readers come and go; file access and playback must not notice.
        let helperFeatures: Set<String> = ["remote/thumbnails", "remote/metadata-helper"]
        let fixed = FixedRemoteSession(PartialRemoteSession(files: provider, previews: provider))
        var operations = FrameMediaOperations()
        operations.metadata = { photo, client, preview, reader in
            let value = await ImageMetadataReader.read(photo: photo, remoteClient: client, remotePreview: preview, videoMetadata: reader)
            if photo.format.isImage, preview != nil { await gate.wait("helper") }
            return value
        }
        let features = FrameComposition(mediaFeatures: FrameMediaFeatures(operations: operations), remoteSession: fixed)
        try await features.setExcluded(helperFeatures)
        XCTAssertNil(features.media.remoteThumbnails)
        XCTAssertNil(features.media.helperMetadata)
        let metadata = try await features.media.readMetadata(video)
        XCTAssertTrue(metadata.identity.contains { $0.label == "Duration" })
        let session = try await features.remotePlaybackRegistry.open(kind: "video", bytes: video.fileSize, request: FramePreviewRequest(photo: video))
        try await waitFor { features.playback.player != nil }
        let player = try XCTUnwrap(features.playback.player)
        let playbackID = features.playbackSettingsID(for: video), metadataID = features.media.metadataGeneration(for: video)
        let imageMetadataID = features.media.metadataGeneration(for: image)
        try await features.setExcluded([])
        XCTAssertNotNil(features.media.remoteThumbnails)
        XCTAssertEqual(features.playbackSettingsID(for: video), playbackID)
        XCTAssertEqual(features.media.metadataGeneration(for: video), metadataID)
        XCTAssertNotEqual(features.media.metadataGeneration(for: image), imageMetadataID)
        let helperFeature = try XCTUnwrap(features.media.helperMetadata)
        let read = Task { try await features.media.readMetadata(image) }
        try await gate.waitFor("helper")
        var drained = false
        let disableHelper = Task {
            try await features.setExcluded(helperFeatures)
            drained = true
        }
        try await waitFor { !helperFeature.isActive }
        XCTAssertFalse(drained)
        XCTAssertTrue(features.playback.player === player)
        XCTAssertFalse(session.isClosed)
        await gate.releaseAll()
        do { _ = try await read.value; XCTFail("Retired helper returned stale metadata") } catch {}
        try await disableHelper.value
        XCTAssertEqual(features.media.metadataGeneration(for: image), imageMetadataID)
        XCTAssertEqual(features.playbackSettingsID(for: video), playbackID)
        try await features.setExcluded([])
        let helperMetadata = try await features.media.readMetadata(image)
        XCTAssertTrue(helperMetadata.identity.contains { $0.label == "Dimensions" && $0.value == "1 × 1" })
        try await features.setExcluded(["thumbnails", "remote/thumbnails"])
        XCTAssertNil(features.registry.descriptor(for: "video.mp4"))
        XCTAssertNil(features.remoteRegistry.descriptor(for: "video.mp4"))
        XCTAssertTrue(features.playback.player === player)
        XCTAssertEqual(features.playbackSettingsID(for: video), playbackID)
        try await features.setEnabled("video", false)
        XCTAssertTrue(session.isClosed)
        XCTAssertNil(features.playback.player)
        XCTAssertNil(player.currentItem)
        XCTAssertNil(features.remotePlaybackRegistry.descriptor(for: "video.mp4"))
        try await features.setEnabled("video", true)
        let next = try await features.remotePlaybackRegistry.open(kind: "video", bytes: video.fileSize, request: FramePreviewRequest(photo: video))
        try await waitFor { features.playback.player != nil }
        fixed.withdraw()
        await features.runtime.settled()
        XCTAssertTrue(next.isClosed)
        XCTAssertNil(features.playback.player)
        XCTAssertNil(features.media.remoteMetadata)
        XCTAssertNotNil(features.playbackRegistry.descriptor(for: "video.mp4"))
        await features.stop()
    }

    func testFormatChoicesPersistAndGateBothPostersAndPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameFormatChoices-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("preferences.json")
        let features = FrameComposition(preferencesURL: storage)
        try await features.start()
        XCTAssertNotNil(features.registry.descriptor(for: "video.mp4"))
        XCTAssertNotNil(features.playbackRegistry.descriptor(for: "video.mp4"))
        try await features.setEnabled("video", false)
        XCTAssertNotNil(features.registry.descriptor(for: "image.png"))
        XCTAssertNil(features.registry.descriptor(for: "video.mp4"))
        XCTAssertNil(features.playbackRegistry.descriptor(for: "video.mp4"))
        try await features.setEnabled("image", false)
        await features.stop()
        let reopened = FrameComposition(preferencesURL: storage)
        try await reopened.start()
        XCTAssertNil(reopened.registry.descriptor(for: "image.png"))
        XCTAssertNil(reopened.playbackRegistry.descriptor(for: "video.mp4"))
        XCTAssertNotNil(reopened.media.metadata, "A format choice never removes a media reader")
        try await reopened.setEnabled("video", true)
        XCTAssertNotNil(reopened.registry.descriptor(for: "video.mp4"))
        XCTAssertNotNil(reopened.playbackRegistry.descriptor(for: "video.mp4"))
        await reopened.stop()
    }

    func testThumbnailWithdrawalJoinsDecoderAndRejectsItsLateImage() async throws {
        let gate = mediaGate(), photo = try photo()
        addTeardownBlock { await gate.releaseAll() }
        var operations = FrameMediaOperations()
        operations.image = { photo, pixels, priority, repository in
            let image = await repository.image(for: photo, maxPixelSize: pixels, priority: priority)
            await gate.wait("image") // Deliberately ignores cancellation after decoding.
            return image
        }
        let features = FrameComposition(mediaFeatures: FrameMediaFeatures(operations: operations))
        try await features.start()
        let feature = try XCTUnwrap(features.media.thumbnails)
        let document = features.active("preview.markdown")?.generation
        let metadata = features.active("metadata")?.generation
        let request = Task { try await feature.image(photo, pixels: 128) }
        try await gate.waitFor("image")
        var drained = false
        let disable = Task {
            try await features.exclude("thumbnails", true)
            drained = true
        }
        try await waitFor { !feature.isActive }
        XCTAssertFalse(drained)
        do { _ = try await feature.image(photo, pixels: 128); XCTFail("Retiring thumbnail admitted a cached request") } catch {}
        await gate.releaseAll()
        do { _ = try await request.value; XCTFail("Late decoded image escaped withdrawal") } catch {}
        try await disable.value
        XCTAssertEqual(features.active("preview.markdown")?.generation, document)
        XCTAssertEqual(features.active("metadata")?.generation, metadata)
        try await features.exclude("thumbnails", false)
        let replacement = try XCTUnwrap(features.media.thumbnails)
        XCTAssertFalse(replacement === feature)
        let image = try await replacement.image(photo, pixels: 128)
        XCTAssertNotNil(image)
        await features.stop()
    }

    func testShutdownOwnsCancelledAndSupersedingMetadataReads() async throws {
        let gate = mediaGate(), first = try photo(), second = try photo("portrait.mov")
        addTeardownBlock { await gate.releaseAll() }
        var operations = FrameMediaOperations()
        operations.metadata = { photo, client, preview, reader in
            let result = await ImageMetadataReader.read(photo: photo, remoteClient: client, remotePreview: preview, videoMetadata: reader)
            await gate.wait(photo.name)
            return result
        }
        let features = FrameComposition(mediaFeatures: FrameMediaFeatures(operations: operations))
        try await features.start()
        let feature = try XCTUnwrap(features.media.metadata)
        let old = Task { try await feature.read(first) }
        try await gate.waitFor(first.name)
        old.cancel()
        let current = Task { try await feature.read(second) }
        try await gate.waitFor(second.name)
        var drained = false
        let shutdown = Task { await features.stop(); drained = true }
        try await waitFor { !feature.isActive }
        await gate.release(second.name)
        do { _ = try await current.value; XCTFail("Current metadata escaped shutdown") } catch {}
        XCTAssertFalse(drained, "A replaced caller's worker is still owned until it finishes")
        await gate.release(first.name)
        do { _ = try await old.value; XCTFail("Cancelled metadata returned a value") } catch {}
        await shutdown.value
        XCTAssertTrue(features.runtime.statuses.isEmpty)
    }

    func testMetadataAndPlaybackWithdrawalLeavesImageRenderingActive() async throws {
        let features = FrameComposition(), photo = try photo()
        try await features.start()
        let imageGeneration = features.active("preview.image")?.generation
        features.preparePlayback(photo)
        try await waitFor { features.playback.player != nil }
        let oldPlayer = try XCTUnwrap(features.playback.player)
        features.playback.toggle()
        try await features.exclude("metadata", true)
        XCTAssertNil(features.playback.player)
        XCTAssertNil(oldPlayer.currentItem)
        XCTAssertEqual(oldPlayer.rate, 0)
        XCTAssertEqual(features.active("preview.image")?.generation, imageGeneration)
        XCTAssertNotNil(features.registry.descriptor(for: "image.png"))
        XCTAssertNil(features.active("playback"))
        try await features.exclude("metadata", false)
        features.preparePlayback(photo)
        try await waitFor { features.playback.player != nil }
        await features.stop()
        XCTAssertNil(features.playback.player)
    }

    func testRemoteMetadataAndWarmThumbnailsStopAtOnceWhenTheSessionEnds() async throws {
        let gate = mediaGate(), local = try photo(), provider = MediaRemoteFixture()
        addTeardownBlock { await gate.releaseAll() }
        let fixed = FixedRemoteSession(PartialRemoteSession(files: provider, previews: provider))
        var photo = local
        photo.remote = RemoteAssetReference(source: BridgeSource(id: String(repeating: "a", count: 64), name: "Media fixture"),
            listingID: UUID(), entry: BridgeEntry(name: local.name, path: "/media/" + local.name, directory: false, size: local.fileSize, modified: "1"))
        var operations = FrameMediaOperations()
        operations.metadata = { photo, client, preview, reader in
            let value = await ImageMetadataReader.read(photo: photo, remoteClient: client, remotePreview: preview, videoMetadata: reader)
            await gate.wait("metadata"); return value
        }
        let features = FrameComposition(mediaFeatures: FrameMediaFeatures(operations: operations), remoteSession: fixed)
        try await features.start()
        let thumbnails = try XCTUnwrap(features.media.remoteThumbnails)
        let metadata = try XCTUnwrap(features.media.remoteMetadata)
        let warm = try await thumbnails.image(photo, pixels: 128)
        XCTAssertNotNil(warm)
        let request = Task { try await metadata.read(photo) }
        try await gate.waitFor("metadata")
        // Withdrawal is synchronous: a warm cache cannot answer once the session has ended.
        fixed.withdraw()
        XCTAssertFalse(metadata.isActive)
        do { _ = try await thumbnails.image(photo, pixels: 128); XCTFail("Cached image bypassed withdrawn authority") } catch {}
        await gate.releaseAll()
        do { _ = try await request.value; XCTFail("Late metadata bypassed withdrawn authority") } catch {}
        await features.stop()
    }

    func testOriginalDownloadIsOwnedIndependentlyOfThumbnailHelper() async throws {
        let gate = mediaGate(), photo = try photo()
        addTeardownBlock { await gate.releaseAll() }
        let provider = MediaRemoteFixture(download: { photo in await gate.wait("download"); return photo })
        let features = FrameComposition.fixture(files: provider)
        try await features.setExcluded(["remote/thumbnails", "remote/metadata-helper"])
        XCTAssertNil(features.media.remoteThumbnails)
        let feature = try XCTUnwrap(features.media.originals)
        let download = Task { try await feature.resolve(photo) }
        try await gate.waitFor("download")
        var drained = false
        let disable = Task {
            try await features.exclude("remote/originals", true)
            drained = true
        }
        try await waitFor { !feature.isActive }
        XCTAssertFalse(drained)
        await gate.releaseAll()
        do { _ = try await download.value; XCTFail("An original file escaped a retired feature") } catch {}
        try await disable.value
        XCTAssertNotNil(features.media.thumbnails)
        XCTAssertNotNil(features.active("playback"))
        await features.stop()
    }
}

private func mediaGate() -> KeyedGate { KeyedGate(failure: "Media worker did not start", timeout: CancellationError()) }

private struct MediaRemoteFixture: RemoteFileReading, RemotePreviewServing {
    var download: @Sendable (PhotoItem) async throws -> PhotoItem = { _ in
        XCTFail("Media information should not download originals"); throw CancellationError()
    }
    var cached: PhotoItem?
    func resolve(_ photo: PhotoItem, includeCompanions: Bool, allowVideo: Bool, priority: Int) async throws -> PhotoItem {
        try await download(photo)
    }
    func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry] { [] }
    func cachedMedia(_ photo: PhotoItem) async -> PhotoItem? { cached }
    func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText] { [] }
    func pin(_ photo: PhotoItem?) async {}
    func preview(_ photo: PhotoItem, pixels: Int, priority: Int) async throws -> BridgeAssetResult {
        var result = BridgeAssetResult()
        result.metadata = ["Dimensions": "1 × 1"]
        result.image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2+XQAAAAASUVORK5CYII=")!
        return result
    }
}
