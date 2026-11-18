import BridgeProtocol
import Foundation
import XCTest
@testable import RelayBar

/// A remote reply never chooses a local path, and a bridge fetch is bounded by the bridge's own limit.
/// Each test owns a short folder below /private/tmp and gives the services a temporary directory two
/// levels further down, so even a write or removal that escapes it stays inside the test's folder.
/// The SFTP and SSH executables are disposable stand-ins: no host, window or app is involved.
@MainActor final class RemoteReplyContainmentTests: XCTestCase {
    private struct Sandbox {
        let root: URL
        let temporary: URL
        let sentinel: URL
    }

    private func sandbox() throws -> Sandbox {
        // Short, so the bridge socket path inside it fits.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("RB-" + UUID().uuidString.prefix(8), isDirectory: true)
        let temporary = root.appendingPathComponent("a/b/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("a/b/sentinel")
        try Data("keep".utf8).write(to: sentinel)
        return Sandbox(root: root, temporary: temporary, sentinel: sentinel)
    }

    /// Nothing beside the temporary directory changed, and nothing is left inside it.
    private func assertContained(_ box: Sandbox, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try String(contentsOf: box.sentinel, encoding: .utf8), "keep", file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: box.temporary.deletingLastPathComponent().path).sorted(),
                       ["sentinel", "tmp"], file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: box.temporary.path), [], file: file, line: line)
    }

    private var fakeSFTP: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-sftp.sh")
    }

    private var server: RemoteServer {
        RemoteServer(id: UUID(), name: "Fixture", sshHost: "success", additionalArguments: [])
    }

    func testPreviewNamesItsLocalFileOnlyAfterTheRequestedFile() async throws {
        let box = try sandbox()
        let service = SFTPRemoteFileService(executableURL: fakeSFTP, fileManager: SandboxTemporaryFileManager(box.temporary),
                                            connectionSharing: false)
        defer { service.shutdown() }
        for name in ["../../escape.md", "nested/escape.md", "", "other.md"] {
            let entry = RemoteFileEntry(name: name, path: "/srv/app/escape.md", kind: .file, size: 10, modificationText: "0")
            do {
                let url = try await service.prepareDocumentResource(server: server, entry: entry)
                XCTFail("Prepared \(name.debugDescription) at \(url.path)")
            } catch { XCTAssertEqual(error as? RemoteFileError, .invalidPath, name) }
        }
        assertContained(box)
        let entry = RemoteFileEntry(name: "escape.md", path: "/srv/app/escape.md", kind: .file, size: 10, modificationText: "0")
        let url = try await service.prepareDocumentResource(server: server, entry: entry)
        XCTAssertEqual(url.lastPathComponent, "escape.md")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().path, box.temporary.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "downloaded")
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        assertContained(box)
    }

    func testHTMLResourceTakesItsNameFromTheRequestAndRemovesOnlyItsOwnFolder() async throws {
        let box = try sandbox()
        let sftp = SFTPRemoteFileService(executableURL: fakeSFTP, fileManager: SandboxTemporaryFileManager(box.temporary),
                                         connectionSharing: false)
        defer { sftp.shutdown() }
        let service = HostileNameService(sftp: sftp, name: "../../escape.css")
        let resources = RemoteHTMLResources(service: service, server: server, root: "/project")
        let data = try await resources.data(at: "assets/style.css")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "downloaded")
        let requested = await service.requestedNames
        XCTAssertEqual(requested, ["style.css"])
        let entry = try await resources.entry(at: "assets/style.css")
        XCTAssertEqual(entry.name, "style.css", "Link navigation gets the requested name too")
        await resources.close()
        assertContained(box)
    }

    func testFrameFetchRefusesANameThatIsNotOneFileName() async throws {
        let box = try sandbox()
        let hostile = BridgeEntry(name: "../../escape.md", path: "/docs/escape.md", directory: false, size: 10,
                                  modified: "0", fingerprint: "1")
        let service = SFTPRemoteFileService(executableURL: fakeSFTP, fileManager: SandboxTemporaryFileManager(box.temporary),
                                            connectionSharing: false, sshExecutableURL: try fakeHelper(in: box, listing: [hostile]))
        let (broker, source) = try broker(box, service: service)
        var list = BridgeRequest("list"); list.sourceID = source.id; list.path = "/docs"
        let listing = try await settle(broker, list)
        XCTAssertEqual(listing.entries?.map(\.name), [hostile.name])
        var fetch = BridgeRequest("fetch"); fetch.listingID = listing.listingID; fetch.name = hostile.name; fetch.path = hostile.path
        let response = try await settle(broker, fetch)
        XCTAssertNotNil(response.error)
        XCTAssertNil(response.cacheRelativePath)
        await broker.shutdown()
        assertContained(box)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.root.appendingPathComponent("escape.md").path))
    }

    func testFrameFetchOfAnOriginalIsBoundedOnlyByTheBridgeLimit() async throws {
        let box = try sandbox()
        let notes = BridgeEntry(name: "notes.md", path: "/docs/notes.md", directory: false, size: 10, modified: "0", fingerprint: "1")
        // RelayBar's own Markdown preview limit is below this file's size; the bridge's limit is far above it.
        let service = SFTPRemoteFileService(executableURL: fakeSFTP, fileManager: SandboxTemporaryFileManager(box.temporary),
                                            markdownPreviewSizeLimit: 4, connectionSharing: false,
                                            sshExecutableURL: try fakeHelper(in: box, listing: [notes]))
        let (broker, source) = try broker(box, service: service)
        var list = BridgeRequest("list"); list.sourceID = source.id; list.path = "/docs"
        let listing = try await settle(broker, list)
        var fetch = BridgeRequest("fetch"); fetch.listingID = listing.listingID; fetch.name = notes.name; fetch.path = notes.path
        let response = try await settle(broker, fetch)
        XCTAssertNil(response.error)
        let cached = box.root.appendingPathComponent(try XCTUnwrap(response.cacheRelativePath))
        XCTAssertEqual(try String(contentsOf: cached, encoding: .utf8), "downloaded")
        var release = BridgeRequest("release"); release.jobID = response.jobID
        _ = broker.handle(release)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        // RelayBar's own preview of the same file keeps its limit.
        let entry = RemoteFileEntry(name: notes.name, path: notes.path, kind: .file, size: 10, modificationText: "0")
        do {
            _ = try await service.preparePreview(server: server, entry: entry)
            XCTFail("RelayBar's Markdown preview limit no longer applies")
        } catch { XCTAssertEqual(error as? RemoteFileError, .markdownTooLarge) }
        await broker.shutdown()
        assertContained(box)
    }

    /// A disposable SSH stand-in that answers the fixed helper's JSON from a file. It never runs the
    /// helper or opens a host: a listing gets `listing`, and a stat check gets an empty, successful reply.
    private func fakeHelper(in box: Sandbox, listing: [BridgeEntry]) throws -> URL {
        var reply = BridgeAssetResult(); reply.entries = listing
        let listingURL = box.root.appendingPathComponent("listing.json")
        try JSONEncoder().encode(reply).write(to: listingURL)
        let script = box.root.appendingPathComponent("ssh-fixture")
        let body = "#!/bin/sh\ninput=$(cat)\ncase \"$input\" in\n*'\"action\":\"list\"'*) cat '\(listingURL.path)' ;;\n*) printf '{}\\n' ;;\nesac\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func broker(_ box: Sandbox, service: SFTPRemoteFileService) throws -> (FrameBridgeBroker, BridgeSource) {
        let suite = "RemoteReplyContainment.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "frameViewer.readAccess.v1")
        let catalog = RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent"))
        _ = try catalog.add(name: "Fixture", sshHost: "success")
        let broker = FrameBridgeBroker(catalog: catalog, defaults: defaults, socketRoot: { box.root }, makeService: { service })
        broker.start()
        return (broker, try XCTUnwrap(broker.handle(BridgeRequest("catalog")).sources?.first))
    }

    /// Answers a request, waiting for its job when it starts one.
    private func settle(_ broker: FrameBridgeBroker, _ request: BridgeRequest) async throws -> BridgeResponse {
        var response = broker.handle(request)
        guard let job = response.jobID else { return response }
        var status = BridgeRequest("status"); status.jobID = job
        for _ in 0..<40 where response.status == "pending" { response = await broker.respond(status, connection: UUID()) }
        XCTAssertEqual(response.status, "ready")
        return response
    }
}

/// Gives a service a disposable temporary directory.
private final class SandboxTemporaryFileManager: FileManager, @unchecked Sendable {
    private let base: URL
    init(_ base: URL) { self.base = base; super.init() }
    override var temporaryDirectory: URL { base }
}

/// A host whose replies carry `name` for every file, in front of a real SFTP service.
private actor HostileNameService: RemoteFileServing {
    let sftp: SFTPRemoteFileService
    let name: String
    private(set) var requestedNames: [String] = []
    init(sftp: SFTPRemoteFileService, name: String) { self.sftp = sftp; self.name = name }
    func frameAsset(server: RemoteServer, input: BridgeAssetInput) async throws -> BridgeAssetResult {
        var result = BridgeAssetResult()
        result.entries = (input.paths ?? []).map {
            BridgeEntry(name: name, path: $0, directory: false, size: 10, modified: "0", fingerprint: "1")
        }
        return result
    }
    func prepareDocumentResource(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        requestedNames.append(entry.name)
        return try await sftp.prepareDocumentResource(server: server, entry: entry)
    }
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] { [] }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws { throw RemoteFileError.missingDownload }
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL { throw RemoteFileError.missingDownload }
}
