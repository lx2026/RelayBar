import BridgeProtocol
import AppKit
import CompositionFixtures
import WebKit
import XCTest
@testable import RelayBar

final class HTMLPreviewTests: XCTestCase {
    func testHTMLRecognitionAndPathContainment() throws {
        for name in ["report.html", "REPORT.HTM"] {
            let entry = RemoteFileEntry(name: name, path: "/project/" + name, kind: .file, size: 1, modificationText: "0")
            XCTAssertTrue(entry.isPreviewableHTML)
            XCTAssertTrue(entry.isPreviewable)
        }
        XCTAssertEqual(try RemoteHTMLResources.normalized("assets/../report.html"), "report.html")
        XCTAssertThrowsError(try RemoteHTMLResources.normalized("../secret"))
        XCTAssertThrowsError(try RemoteHTMLResources.normalized("assets/../../secret"))
    }

    @MainActor func testModelRendersHTMLWithRelativeAndOnlineResourcesAndCleansUp() async throws {
        QuietWindow.prepareTestProcess()
        let online = try await HTMLHTTPFixture(files: [
            "/online.js": "window.onlineScript=true",
            "/online.css": "h1{color:rgb(10, 50, 90)}",
            "/data.json": "{\"value\":73}"
        ])
        defer { online.stop() }
        let service = HTMLTestService(online: online.baseURL)
        let tunnel = Tunnel(name: "Fixture", localPort: 8080, destinationHost: "localhost", destinationPort: 3000, sshHost: "fixture.invalid")
        let suite = "HTMLPreviewTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent"))
        let model = RemoteFilesModel(tunnels: [tunnel], service: service, serverCatalog: catalog)
        model.remotePath = "/project"; model.openRemotePath()
        try await wait { model.screen == .browser && !model.isLoading }
        let history = catalog.recentLocations(from: [tunnel])
        let entry = try XCTUnwrap(model.entries.first { $0.name == "report.html" })
        model.preview(entry)
        try await wait { model.previewHTML != nil || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        let renderer = try XCTUnwrap(model.previewHTML)
        let window = QuietWindow(size: NSSize(width: 900, height: 600), styleMask: [.titled])
        window.contentView = renderer.webView
        defer { renderer.stop(); window.contentView = nil }
        try await waitJS(renderer.webView, "window.localValue === 42 && window.onlineScript === true && window.onlineValue === 73 && getComputedStyle(document.querySelector('h1')).color === 'rgb(10, 50, 90)'")
        XCTAssertNil(renderer.error)
        XCTAssertFalse(renderer.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(RemoteHTMLFocus.ownsKeys(renderer.webView))
        let field = NSTextView(); renderer.webView.addSubview(field)
        XCTAssertTrue(RemoteHTMLFocus.ownsKeys(field)); field.removeFromSuperview()
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('input').value='typed';fetch('file:///etc/passwd').catch(()=>window.fileBlocked=true);'ok'")
        try await waitJS(renderer.webView, "window.fileBlocked === true")
        let fetched = await service.fetches
        XCTAssertEqual(Set(fetched), ["report.html", "assets/app.js", "assets/data.json"])
        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(catalog.recentLocations(from: [tunnel]), history)
        XCTAssertEqual(model.previewEntry?.id, entry.id)
        let temporary = await service.temporaryFolders
        XCTAssertTrue(temporary.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        model.closePreview()
        XCTAssertNil(model.previewHTML)
        XCTAssertEqual(model.selectedEntryID, entry.id)
        await renderer.resources.close()
        do { _ = try await renderer.resources.data(at: "report.html"); XCTFail("Closed preview still serves data") } catch is CancellationError {}
    }

    func testResourcesRejectMissingAndOversizedFilesWithoutDownloading() async throws {
        let service = HTMLTestService(online: "http://127.0.0.1:1")
        let source = RemoteServer(id: UUID(), name: "Fixture", sshHost: "fixture.invalid", additionalArguments: [])
        let resources = RemoteHTMLResources(service: service, server: source, root: "/project")
        for path in ["../secret", "symlink/secret", "huge.html"] {
            do { _ = try await resources.data(at: path, limit: 10); XCTFail("Read \(path)") } catch {}
        }
        let fetched = await service.fetches
        XCTAssertTrue(fetched.isEmpty)
        await resources.close()
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("Timed out waiting for preview")
    }
    @MainActor private func waitJS(_ view: WKWebView, _ condition: String) async throws {
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("WebKit condition failed: \(condition)")
    }
}

private actor HTMLTestService: RemoteFileServing {
    let files: [String: String]
    var fetches: [String] = []
    var temporaryFolders: [URL] = []
    init(online: String) {
        files = [
            "report.html": "<h1>Report</h1><input><script src='assets/app.js'></script><script src='\(online)/online.js'></script><link rel='stylesheet' href='\(online)/online.css'><script>fetch('\(online)/data.json').then(r=>r.json()).then(v=>window.onlineValue=v.value)</script>",
            "assets/app.js": "fetch('assets/data.json').then(r=>r.json()).then(v=>window.localValue=v.value)",
            "assets/data.json": "{\"value\":42}",
            "huge.html": String(repeating: "x", count: 100), "unused.mp4": "unused"
        ]
    }
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        files.keys.filter { !$0.contains("/") }.map { entry($0) }
    }
    private func entry(_ path: String) -> RemoteFileEntry {
        RemoteFileEntry(name: (path as NSString).lastPathComponent, path: "/project/" + path,
            kind: .file, size: Int64(files[path]!.utf8.count), modificationText: "0")
    }
    func frameAsset(server: RemoteServer, input: BridgeAssetInput) async throws -> BridgeAssetResult {
        guard input.action == "documentStat", input.root == "/project" else { throw RemoteFileError.invalidPath }
        var result = BridgeAssetResult()
        result.entries = (input.paths ?? []).compactMap { path in
            guard path.hasPrefix("/project/") else { return nil }
            let relative = String(path.dropFirst(9))
            guard files[relative] != nil else { return nil }
            let file = entry(relative)
            return BridgeEntry(name: file.name, path: file.path, directory: false, size: file.size!, modified: "0", fingerprint: "1")
        }
        return result
    }
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        let path = String(entry.path.dropFirst(9)); fetches.append(path)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RelayHTMLTest-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryFolders.append(folder)
        let url = folder.appendingPathComponent(entry.name)
        try Data(files[path]!.utf8).write(to: url)
        return url
    }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        throw RemoteFileError.missingDownload
    }
}
