import AppKit
import CompositionFixtures
import Composition
import XCTest
@testable import RelayBar

@MainActor
final class RelayBarCompositionTests: XCTestCase {
    func testPreferencesImportOnceAndFailedSaveLeavesLiveUpdaterUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPreferences-\(UUID())")
        let suite = "RelayPreferences.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(7, forKey: "sshRetryLimit.v1")
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let url = root.appendingPathComponent("preferences.json")
        let backup = url.appendingPathExtension("previous")
        let updater = PreferencesUpdateService()
        func makeApp() -> RelayBarComposition {
            RelayBarComposition(defaults: defaults, preferencesURL: url, startsBridge: false, showsWindows: false,
                makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
                makeUpdates: { _ in updater }, loginService: CompositionLoginService())
        }
        let app = makeApp()
        await app.start()
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.store?.maxRetryAttempts, 7)
        XCTAssertTrue(app.updates.automaticallyChecksForUpdates)
        XCTAssertEqual(updater.changes, [true])
        let generation = try XCTUnwrap(app.runtime.status("updates")?.generation)
        let model = app.updates

        // A save that fails changes neither the document nor any live service.
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        do { try await app.setAutomaticUpdates(false); XCTFail("Save should fail") } catch {}
        XCTAssertTrue(app.updates.automaticallyChecksForUpdates)
        XCTAssertEqual(updater.changes, [true])
        XCTAssertTrue(app.updates === model)
        try FileManager.default.removeItem(at: backup)

        try await app.setAutomaticUpdates(false)
        try await app.setRetryLimit(3)
        XCTAssertEqual(updater.changes, [true, false], "Unrelated commits must not reset the update cycle")
        XCTAssertEqual(app.runtime.status("updates")?.generation, generation)
        XCTAssertEqual(updater.starts, 1)
        XCTAssertEqual(app.store?.maxRetryAttempts, 3)
        XCTAssertEqual(defaults.integer(forKey: "sshRetryLimit.v1"), 7, "The preference document owns the limit")
        do { try await app.setRetryLimit(500); XCTFail("Invalid limit accepted") } catch {}
        XCTAssertEqual(app.store?.maxRetryAttempts, 3)

        // Only choices are stored: no grants, no saved profiles, and no feature wiring.
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["readAccess", "savedTunnels", "tunnels", "frame.host", "remote.files", "updates.schedule"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertTrue(defaults.bool(forKey: "frameViewer.readAccess.v1"))
        await app.stop()
        XCTAssertNil(app.store)

        defaults.set(99, forKey: "sshRetryLimit.v1")
        let reopened = makeApp()
        await reopened.start()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.store?.maxRetryAttempts, 3)
        XCTAssertFalse(reopened.updates.automaticallyChecksForUpdates)
        await reopened.stop()
        await reopened.start()
        XCTAssertEqual(reopened.store?.maxRetryAttempts, 3, "A stopped composition can start again")
        await reopened.stop()
    }

    func testPreferencesFromANewerVersionAreNeverAppliedOrOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayFuture-\(UUID())")
        let suite = "RelayFuture.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("preferences.json")
        let future = Data(#"{"version":99,"preferences":{"layout":"new"}}"#.utf8)
        try future.write(to: url)
        let app = RelayBarComposition(defaults: defaults, preferencesURL: url, startsBridge: false, showsWindows: false,
            makeUpdates: { _ in UnavailableUpdateService() }, loginService: CompositionLoginService())
        await app.start()
        XCTAssertNotNil(app.errorMessage)
        XCTAssertNil(app.store, "Nothing starts from preferences this version cannot read")
        XCTAssertEqual(try Data(contentsOf: url), future)
        await app.stop()
    }

    func testPackageFeatureJoinsLeavesAndReturnsWithOnlyANode() async throws {
        let suite = "RelayFeature.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let fixture = [FeatureNode("fixture") { FileProbe(file: file, notification: suite) }]
        let app = RelayBarComposition(defaults: defaults, startsBridge: false, showsWindows: false,
            makeUpdates: { _ in UnavailableUpdateService() }, loginService: CompositionLoginService(),
            additionalFeatures: fixture)
        await app.start()
        XCTAssertNil(app.errorMessage)
        let generation = app.runtime.status("tunnels")?.generation
        NotificationCenter.default.post(name: Notification.Name(suite), object: nil)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "observed")
        try await app.setAdditionalFeatures([])
        NotificationCenter.default.post(name: Notification.Name(suite), object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await app.setAdditionalFeatures(fixture)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "active")
        try await app.setAdditionalFeatures([])
        NotificationCenter.default.post(name: Notification.Name(suite), object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(app.runtime.status("tunnels")?.generation, generation)
        await app.stop()
    }

    func testAFeatureThatFailsIsReportedWithItsReasonAndOthersKeepRunning() async throws {
        struct Broken: Feature {
            func run(_ context: FeatureContext) async throws { throw CompositionError("socket path is occupied") }
        }
        let suite = "RelayBroken.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = RelayBarComposition(defaults: defaults, startsBridge: false, showsWindows: false,
            makeUpdates: { _ in UnavailableUpdateService() }, loginService: CompositionLoginService(),
            additionalFeatures: [FeatureNode("fixture.broken") { Broken() }])
        await app.start()
        XCTAssertEqual(app.errorMessage, "fixture.broken: socket path is occupied")
        XCTAssertNotNil(app.store)
        XCTAssertEqual(app.runtime.unavailable.map(\.id), ["fixture.broken"])
        await app.stop()
    }

    func testWindowAppliesSavedPreviewSettingsWithoutRestartingOtherFeatures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayComposition-\(UUID())")
        let suite = "RelayComposition.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let service = CompositionFileService(root: root)
        let app = RelayBarComposition(defaults: defaults, preferencesURL: url, startsBridge: false, showsWindows: false,
            makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
            makeFileService: { service }, makeUpdates: { _ in UnavailableUpdateService() }, loginService: CompositionLoginService())
        await app.start()
        XCTAssertNil(app.errorMessage)
        let tunnelGeneration = try XCTUnwrap(app.runtime.status("tunnels")?.generation)
        XCTAssertNil(app.windows)
        try await app.setPreviewEnabled("json", false)
        let saved = try Data(contentsOf: url)

        // Opening the window is not a preference: nothing is written.
        try await app.setRemoteFilesOpen(true)
        XCTAssertNotNil(app.windows)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let registry = try XCTUnwrap(app.runtime.service(RelayServices.PreviewRegistry.self))
        XCTAssertNil(registry.descriptor(for: "sample.json"))
        XCTAssertNil(app.runtime.status("remote.files/preview.json"))
        let image = try await registry.open(filename: "image.png", bytes: 68, request: request())
        XCTAssertNotNil(image.content.image)
        let window = app.windows

        try await app.setPreviewEnabled("image", false)
        XCTAssertTrue(image.isClosed)
        XCTAssertTrue(app.windows === window)
        XCTAssertEqual(app.runtime.status("tunnels")?.generation, tunnelGeneration)
        XCTAssertNotNil(registry.descriptor(for: "sample.md"))

        // A lower limit reloads that one format and nothing else.
        let markdown = try XCTUnwrap(app.runtime.status("remote.files/preview.markdown")?.generation)
        let video = try XCTUnwrap(app.runtime.status("remote.files/preview.video")?.generation)
        try await app.setPreviewLimit("markdown", 1_024)
        XCTAssertEqual(registry.descriptor(for: "sample.md")?.maximumBytes, 1_024)
        XCTAssertEqual(app.runtime.status("remote.files/preview.markdown")?.generation, markdown + 1)
        XCTAssertEqual(app.runtime.status("remote.files/preview.video")?.generation, video)
        do { try await app.setPreviewLimit("markdown", Int64.max); XCTFail("Limit above the format's maximum accepted") } catch {}
        XCTAssertTrue(app.windows === window)

        try await app.setRemoteFilesOpen(false)
        XCTAssertNil(app.windows)
        XCTAssertTrue(registry.descriptors.isEmpty)
        XCTAssertGreaterThan(service.shutdownCount, 0)
        try await app.setRemoteFilesOpen(true)
        XCTAssertNil(app.runtime.status("remote.files/preview.image"))
        XCTAssertNil(app.runtime.status("remote.files/preview.json"))
        XCTAssertEqual(app.runtime.status("remote.files/preview.html")?.isActive, true)
        await app.stop()
        XCTAssertTrue(app.runtime.statuses.isEmpty)
        XCTAssertNil(app.store)
    }

    private func request() -> RelayPreviewRequest {
        RelayPreviewRequest(entry: .init(name: "image.png", path: "/fixture/image.png", kind: .file, size: 68, modificationText: "0"),
            server: .init(id: UUID(), name: "Fixture", sshHost: "fixture.invalid", additionalArguments: []),
            root: "/fixture", progress: { _ in }, preparingVideo: {}, navigate: { _ in }, navigationError: { _ in })
    }
}

private struct CompositionLoginService: LoginItemServicing {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openLoginItemsSettings() {}
}

@MainActor
private final class PreferencesUpdateService: UpdateServicing {
    let isAvailable = true
    let canCheckForUpdates = true
    let deferredInstallTunnelCount: Int? = nil
    var stateDidChange: (@MainActor () -> Void)?
    var changes: [Bool] = []
    var starts = 0
    var automaticallyChecksForUpdates = false { didSet { changes.append(automaticallyChecksForUpdates) } }
    func start() { starts += 1 }
    func stop() async { stateDidChange = nil }
    func checkForUpdates(completion: @escaping @MainActor (UpdateCheckResult) -> Void) { completion(.upToDate) }
    func prepareForApplicationTermination() -> Bool { false }
}

private final class CompositionFileService: RemoteFileServing, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var shutdowns = 0
    var shutdownCount: Int { lock.lock(); defer { lock.unlock() }; return shutdowns }
    init(root: URL) { self.root = root }
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] { [] }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {}
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(entry.name)
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2+XQAAAAASUVORK5CYII=")!.write(to: url)
        return url
    }
    func shutdown() { lock.lock(); shutdowns += 1; lock.unlock() }
}
