import AppKit
import Composition
import CompositionFixtures
import PreviewSupport
import XCTest
@testable import FrameKit

@MainActor
final class PreviewPluginTests: XCTestCase {
    func testTextExtensionsComeFromCodeAndSavedChoicesPersist() async throws {
        let storage = try root().appendingPathComponent("preferences.json")
        let first = FrameComposition(preferencesURL: storage)
        try await first.setEnabled("text", false)
        try await first.setMaximumBytes("text", 2048)
        await first.stop()
        // The document stores the choice, never the format's extension list.
        XCTAssertFalse(try String(contentsOf: storage, encoding: .utf8).contains("extensions"))
        let reopened = FrameComposition(preferencesURL: storage)
        try await reopened.start()
        XCTAssertFalse(reopened.enabledKinds.contains("text"))
        XCTAssertEqual(reopened.maximumBytes("text"), 2048)
        try await reopened.setEnabled("text", true)
        for ext in PhotoFormat.textExtensions {
            XCTAssertEqual(PhotoFormat.browsing(pathExtension: ext), .text)
            XCTAssertEqual(reopened.registry.descriptor(for: "file." + ext)?.id, "text")
        }
        do { try await reopened.setMaximumBytes("text", Int64.max); XCTFail("A limit above the format's maximum was accepted") } catch {}
        await reopened.stop()
    }

    func testPackageFeatureJoinsLeavesAndReturnsWithOnlyANode() async throws {
        let file = try root().appendingPathComponent("probe"), name = UUID().uuidString
        let fixture = [FeatureNode("fixture") { FileProbe(file: file, notification: name) }]
        let features = FrameComposition(additionalFeatures: fixture)
        try await features.start()
        let generation = features.active("preview.image")?.generation
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "observed")
        try await features.exclude("fixture", true)
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await features.exclude("fixture", false)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "active")
        try await features.setAdditionalFeatures([])
        NotificationCenter.default.post(name: Notification.Name(name), object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(features.active("preview.image")?.generation, generation)
        await features.stop()
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameComposition-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func image(_ root: URL) throws -> PhotoItem {
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2+XQAAAAASUVORK5CYII=")!
        try data.write(to: root.appendingPathComponent("image.png"))
        return try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: UUID()).photos.first)
    }

    func testPreviewModulesActivateAndToggleWithoutLeakingExistingResults() async throws {
        let photo = try image(root())
        let plugins = FrameComposition()
        try await plugins.start()
        XCTAssertEqual(Set(plugins.registry.descriptors.map(\.id)), Set(FrameComposition.descriptors.map(\.id)))
        XCTAssertEqual(plugins.registry.descriptor(for: "notes.mkd")?.id, "markdown")
        XCTAssertEqual(plugins.registry.descriptor(for: "image.webp")?.id, "image")
        try await plugins.setPlugin(PreviewPlugins.moreImages, enabled: false)
        XCTAssertNil(plugins.registry.descriptor(for: "image.webp"))
        XCTAssertEqual(plugins.registry.descriptor(for: "image.png")?.id, "image")
        try await plugins.setPlugin(PreviewPlugins.moreImages, enabled: true)
        XCTAssertTrue(plugins.runtime.statuses.filter { $0.id.hasPrefix("preview.") }.allSatisfy(\.isActive))
        XCTAssertTrue(plugins.remoteRegistry.descriptors.isEmpty)
        // Without a session every feature in the remote realm waits, and says what for.
        let remote = plugins.runtime.statuses.filter { $0.id.hasPrefix("remote/") }
        XCTAssertFalse(remote.isEmpty)
        XCTAssertTrue(remote.allSatisfy { if case .pending = $0.phase { return true }; return false })
        XCTAssertEqual(plugins.runtime.status("remote/source")?.phase, .pending("Needs RelaySession from relay.link"))
        let first = try await plugins.image(photo, pixels: 128)
        XCTAssertNotNil(first.content.image)
        try await plugins.setEnabled("image", false)
        XCTAssertTrue(first.isClosed)
        XCTAssertNotNil(plugins.registry.descriptor(for: "other.html"))
        do { _ = try await plugins.image(photo, pixels: 128); XCTFail("Disabled image renderer still available") } catch {}
        try await plugins.setEnabled("image", true)
        let next = try await plugins.image(photo, pixels: 128)
        XCTAssertNotNil(next.content.image)
        await plugins.stop()
        XCTAssertTrue(next.isClosed)
        XCTAssertTrue(plugins.registry.descriptors.isEmpty)
    }

    func testPreviewSettingsSurviveRestartAndEnforceSizeLimit() async throws {
        let root = try root(), photo = try image(root)
        let storage = root.appendingPathComponent("preferences.json")
        let plugins = FrameComposition(preferencesURL: storage)
        try await plugins.setEnabled("html", false)
        try await plugins.setMaximumBytes("image", 1)
        await plugins.stop()
        let reopened = FrameComposition(preferencesURL: storage)
        try await reopened.start()
        XCTAssertFalse(reopened.enabledKinds.contains("html"))
        XCTAssertEqual(reopened.maximumBytes("image"), 1)
        do { _ = try await reopened.image(photo, pixels: 128); XCTFail("Configured byte limit ignored") } catch {}
        XCTAssertNotNil(reopened.registry.descriptor(for: "notes.md"))
        await reopened.stop()
    }

    func testDocumentLimitChecksActualBytesAndDisablingStopsRenderer() async throws {
        QuietWindow.prepareTestProcess()
        let root = try root()
        try Data("# Larger than the configured limit".utf8).write(to: root.appendingPathComponent("notes.md"))
        var photo = try XCTUnwrap(FileScanner.scan(rootURL: root, rootID: UUID()).photos.first)
        photo = PhotoItem(id: photo.id, rootID: photo.rootID, url: photo.url, relativePath: photo.relativePath,
            folderRelativePath: "", name: photo.name, format: .markdown, fileSize: 1,
            createdAt: nil, modifiedAt: nil, fileIdentifier: nil)
        let plugins = FrameComposition()
        try await plugins.setMaximumBytes("markdown", 2)
        plugins.showDocument(photo, path: "notes.md", location: .local(root))
        for _ in 0..<200 where plugins.documentRenderer.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(plugins.documentRenderer.error?.contains("limit") == true)
        try await plugins.setEnabled("markdown", false)
        XCTAssertEqual(plugins.documentRenderer.error, "Preview is disabled. Enable it in Settings.")
        plugins.documentRenderer.retry()
        XCTAssertFalse(plugins.documentRenderer.loading)
        await plugins.stop()
    }
}
