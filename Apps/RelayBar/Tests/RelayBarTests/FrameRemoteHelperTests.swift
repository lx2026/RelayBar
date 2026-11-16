import BridgeProtocol
import AssetGrouping
import CompositionFixtures
import AppKit
import Foundation
import XCTest
@testable import RelayBar

final class FrameRemoteHelperTests: XCTestCase {
    func testSharedCompanionFixturesRoundTripThroughFixedPythonHelper() throws {
        for sample in CompanionGroupingFixture.all {
            let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("HelperGrouping-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            for name in sample.files {
                let file = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(name.utf8).write(to: file)
            }
            let directories = Set(sample.files.map { ($0 as NSString).deletingLastPathComponent })
            for primary in sample.files.filter(AssetCompanionNames.isPrimary) {
                // Read fresh fingerprints after each restore, using the actual Python listing.
                let listing = try directories.sorted().flatMap { try entries(root.appendingPathComponent($0)) }
                let entry = try XCTUnwrap(listing.first { $0.path == root.appendingPathComponent(primary).path })
                let companions = FrameBridgeBroker.companions(for: entry, entries: listing)
                let expected = sample.groups[primary] ?? []
                XCTAssertEqual(companions.map { String($0.path.dropFirst(root.path.count + 1)) }, expected, sample.name)
                let moved = Set([primary] + expected)
                let archived = try move(root, action: "archive", members: [entry] + companions)
                XCTAssertNil(archived.error, sample.name)
                for name in sample.files {
                    XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), !moved.contains(name), "\(sample.name): \(name)")
                }
                var restore = BridgeAssetInput(action: "restore", root: root.path)
                restore.recordID = try XCTUnwrap(archived.recordID)
                XCTAssertNil(try call(restore).error)
                for name in moved { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8), name) }
            }
        }
    }

    func testDocumentStatBatchesChangesAndRejectsEscapes() throws {
        let root = try fixture()
        try Data("# Notes".utf8).write(to: root.appendingPathComponent("notes.md"))
        var input = BridgeAssetInput(action: "documentStat", root: root.path)
        input.paths = [root.appendingPathComponent("notes.md").path, root.appendingPathComponent("a.jpg").path]
        let first = try call(input)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.entries?.count, 2)
        try Data("# Updated".utf8).write(to: root.appendingPathComponent("notes.md"), options: .atomic)
        let second = try call(input)
        XCTAssertNotEqual(first.entries?.first?.fingerprint, second.entries?.first?.fingerprint)
        input.paths = [root.path + "/../secret"]
        XCTAssertNotNil(try call(input).error)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("notes.md"))
        input.paths = [root.appendingPathComponent("link.md").path]
        XCTAssertNotNil(try call(input).error)
        input.paths = Array(repeating: root.appendingPathComponent("notes.md").path, count: 129)
        XCTAssertNotNil(try call(input).error)
    }
    func testDocumentArchiveRestoreAndDeleteKeepSiblingDependencies() throws {
        let root = try fixture()
        for name in ["a.html", "a.md", "a.css", "a.js"] { try Data("fixture".utf8).write(to: root.appendingPathComponent(name)) }
        let listing = try entries(root)
        let page = try XCTUnwrap(listing.first { $0.name == "a.html" })
        XCTAssertTrue(FrameBridgeBroker.companions(for: page, entries: listing).isEmpty)
        let image = try XCTUnwrap(listing.first { $0.name == "a.jpg" })
        XCTAssertFalse(FrameBridgeBroker.companions(for: image, entries: listing).contains { ["a.html", "a.md"].contains($0.name) })
        let result = try move(root, action: "archive", members: [page])
        XCTAssertNil(result.error)
        var restore = BridgeAssetInput(action: "restore", root: root.path); restore.recordID = result.recordID
        XCTAssertNil(try call(restore).error)
        let current = try XCTUnwrap(try entries(root).first { $0.name == "a.html" })
        XCTAssertNil(try move(root, action: "delete", members: [current]).error)
        for name in ["a.md", "a.css", "a.js", "a.jpg"] { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
    }
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/FrameHelperTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("original media".utf8).write(to: root.appendingPathComponent("a.jpg"))
        try Data("{\"prompt\":\"fixture\"}".utf8).write(to: root.appendingPathComponent("a.jpg.json"))
        return root
    }
    private func call(_ input: BridgeAssetInput, script: String = FrameRemoteHelper.script) throws -> BridgeAssetResult {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FRAME_HELPER_PYTHON"] ?? "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(input))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try JSONDecoder().decode(BridgeAssetResult.self, from: data)
    }
    private func entries(_ root: URL) throws -> [BridgeEntry] {
        let result = try call(BridgeAssetInput(action: "list", root: root.path))
        XCTAssertNil(result.error)
        return try XCTUnwrap(result.entries)
    }
    private func move(_ root: URL, action: String, members: [BridgeEntry]) throws -> BridgeAssetResult {
        var input = BridgeAssetInput(action: action, root: root.path)
        input.members = members
        return try call(input)
    }
    func testPairedArchiveRestoreAndNoClobber() throws {
        let root = try fixture(), members = try entries(root)
        let result = try move(root, action: "archive", members: members)
        XCTAssertNil(result.error)
        let id = try XCTUnwrap(result.recordID)
        XCTAssertTrue(try entries(root).isEmpty, "Managed Archive is excluded from browsing")
        let query = BridgeAssetInput(action: "collection", root: root.path)
        let archived = try call(query)
        XCTAssertEqual(archived.records?.first?.members.count, 2)
        var restore = BridgeAssetInput(action: "restore", root: root.path); restore.recordID = id
        let conflict = root.appendingPathComponent("a.jpg.json")
        try Data("existing".utf8).write(to: conflict)
        XCTAssertNotNil(try call(restore).error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.jpg").path))
        XCTAssertEqual(try String(contentsOf: conflict), "existing")
        try FileManager.default.removeItem(at: conflict)
        XCTAssertNil(try call(restore).error)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.jpg")), "original media")
        XCTAssertEqual(try entries(root).count, 2)
    }
    func testDeletePermanentlyRemovesMediaAndJSONWithoutCreatingAnything() throws {
        let root = try fixture()
        let result = try move(root, action: "delete", members: entries(root))
        XCTAssertNil(result.error)
        XCTAssertNil(result.recordID)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testArbitraryCompanionGroupArchiveRestoreAndPermanentDelete() throws {
        let root = try fixture()
        for name in ["a.xyz.json", "a.qqq.txt", "a.bin"] {
            try Data("companion".utf8).write(to: root.appendingPathComponent(name))
        }
        let listing = try entries(root)
        let media = try XCTUnwrap(listing.first { $0.name == "a.jpg" })
        let members = [media] + FrameBridgeBroker.companions(for: media, entries: listing)
        XCTAssertEqual(members.count, 5)
        let archived = try move(root, action: "archive", members: members)
        XCTAssertNil(archived.error)
        let collection = try call(BridgeAssetInput(action: "collection", root: root.path))
        XCTAssertNil(collection.error)
        XCTAssertEqual(collection.records?.first?.members.count, 5)
        var restore = BridgeAssetInput(action: "restore", root: root.path); restore.recordID = try XCTUnwrap(archived.recordID)
        XCTAssertNil(try call(restore).error)
        let restored = try entries(root)
        let current = try XCTUnwrap(restored.first { $0.name == "a.jpg" })
        XCTAssertNil(try move(root, action: "delete", members: [current] + FrameBridgeBroker.companions(for: current, entries: restored)).error)
        XCTAssertTrue(try entries(root).isEmpty)
    }
    func testBatchDeleteHundredPairsWithOneChangedAsset() throws {
        let root = try fixture()
        for index in 0..<100 {
            for suffix in [".jpg", ".jpg.json"] {
                try Data("fixture".utf8).write(to: root.appendingPathComponent("\(index)" + suffix))
            }
        }
        let listing = try entries(root)
        var input = BridgeAssetInput(action: "deleteBatch", root: root.path)
        input.batch = (0..<100).map { index in
            var asset = BridgeAssetInput(action: "delete", root: root.path)
            asset.members = listing.filter { $0.name == "\(index).jpg" || $0.name == "\(index).jpg.json" }
                .sorted { $0.name < $1.name }
            return asset
        }
        try Data("changed content".utf8).write(to: root.appendingPathComponent("40.jpg"))
        let result = try call(input)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outcomes?.count, 100)
        XCTAssertEqual(result.outcomes?.filter { $0.error != nil }.map { ($0.path as NSString).lastPathComponent }, ["40.jpg"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["a.jpg", "a.jpg.json", "40.jpg", "40.jpg.json"])
    }
    func testStaleSameSizeFileAndSymlinksRejected() throws {
        let root = try fixture(), members = try entries(root)
        try Data("changed! media".utf8).write(to: root.appendingPathComponent("a.jpg"))
        XCTAssertNotNil(try move(root, action: "delete", members: members).error)
        XCTAssertEqual(try entries(root).count, 2, "A stale member must not delete its paired JSON")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.path)
        XCTAssertFalse(try entries(root).contains { $0.name == "link" })
        let unsafe = try call(BridgeAssetInput(action: "list", root: root.appendingPathComponent("link").path))
        XCTAssertNotNil(unsafe.error)
        XCTAssertNotNil(try call(BridgeAssetInput(action: "list", root: root.path + "/../")).error)
    }
    func testUnmanagedArchiveAndEscapingManifestRejected() throws {
        let root = try fixture(), members = try entries(root)
        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        XCTAssertNotNil(try move(root, action: "archive", members: members).error)
        XCTAssertEqual(try entries(root).filter { !$0.directory }.count, 2)
        try FileManager.default.removeItem(at: archive)
        let result = try move(root, action: "archive", members: members)
        let id = try XCTUnwrap(result.recordID)
        let manifest = root.appendingPathComponent("Archive/\(id.uuidString.lowercased())/.frame-asset.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "originals": ["/tmp/not-this-folder.jpg"]]).write(to: manifest)
        var restore = BridgeAssetInput(action: "restore", root: root.path); restore.recordID = id
        XCTAssertNotNil(try call(restore).error)
    }
    func testSecondMemberFailureRollsBackFirstAndKeepsOriginals() throws {
        let root = try fixture(), members = try entries(root)
        let script = FrameRemoteHelper.script.replacingOccurrences(of: "newfp=move_one(src,dst,fp); moved.append((dst,src,newfp))",
            with: "if len(moved)==1: raise OSError('injected failure')\n            newfp=move_one(src,dst,fp); moved.append((dst,src,newfp))")
        var input = BridgeAssetInput(action: "archive", root: root.path); input.members = members
        XCTAssertNotNil(try call(input, script: script).error)
        XCTAssertEqual(try entries(root).count, 2)
    }
    func testPreviewDimensionsMetadataAndConditionalCache() throws {
        guard ProcessInfo.processInfo.environment["FRAME_HELPER_PYTHON"] != nil else { throw XCTSkip("Set FRAME_HELPER_PYTHON to Python 3 with Pillow.") }
        let root = try fixture()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 2250, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 3
                pixels[offset] = UInt8(truncatingIfNeeded: x * 37 + y * 13)
                pixels[offset+1] = UInt8(truncatingIfNeeded: x / 8 + y / 8)
                pixels[offset+2] = UInt8(truncatingIfNeeded: y * 71 + x * 11)
            }
        }
        let original = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.97]))
        try original.write(to: root.appendingPathComponent("a.jpg"))
        try Data("{\"seed\":42}".utf8).write(to: root.appendingPathComponent("a.xyz.json"))
        try Data("Useful text companion.".utf8).write(to: root.appendingPathComponent("a.qqq.txt"))
        let listing = try entries(root), media = try XCTUnwrap(listing.first { $0.name == "a.jpg" })
        var input = BridgeAssetInput(action: "preview", root: root.path)
        input.members = [media] + FrameBridgeBroker.companions(for: media, entries: listing); input.pixels = 512
        let start = Date()
        let result = try call(input)
        XCTAssertNil(result.error)
        let image = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(result.image)))
        XCTAssertEqual(image.pixelsWide, 512)
        XCTAssertEqual(result.metadata?["Dimensions"], "4000 × 2250")
        XCTAssertLessThan(try XCTUnwrap(result.image).count, original.count / 10)
        print("PERFORMANCE remote-helper original=\(original.count) preview=\(result.image?.count ?? 0) cold-seconds=\(Date().timeIntervalSince(start))")
        XCTAssertTrue(result.sidecar?.contains("fixture") == true)
        XCTAssertEqual(result.companions?.count, 3)
        XCTAssertEqual(result.companions?.first { $0.name == "a.qqq.txt" }?.text, "Useful text companion.")
        input.fingerprint = result.fingerprint
        let unchanged = try call(input)
        XCTAssertEqual(unchanged.unchanged, true)
        XCTAssertNil(unchanged.image)
    }
    func testCommandNeverInterpolatesPathsOrWeakensHostKeyVerification() throws {
        let server = RemoteServer(id: UUID(), name: "Fixture", sshHost: "fixture.invalid", additionalArguments: ["-J", "jump"])
        let args = try FrameRemoteHelper.arguments(server: server, socket: URL(fileURLWithPath: "/tmp/socket"))
        XCTAssertTrue(args.contains("-S"))
        XCTAssertTrue(args.contains("-J"))
        XCTAssertFalse(args.joined(separator: " ").contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(args.last?.hasPrefix("python3 -c '") == true)
    }
    func testDeleteFromArchiveRemovesPairAndRecord() throws {
        let root = try fixture()
        let archived = try move(root, action: "archive", members: entries(root))
        let query = BridgeAssetInput(action: "collection", root: root.path)
        let record = try XCTUnwrap(call(query).records?.first)
        var deletion = BridgeAssetInput(action: "delete", root: root.path)
        deletion.recordID = archived.recordID; deletion.members = record.members
        XCTAssertNil(try call(deletion).error)
        XCTAssertTrue(try call(query).records?.isEmpty == true)
        XCTAssertTrue(try entries(root).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Archive").path), [".frame-remote"])
    }
    func testDeleteLeavesUnselectedFilesAndDoesNotFollowSymlinks() throws {
        let root = try fixture(), members = try entries(root)
        let kept = root.appendingPathComponent("keep.jpg")
        try Data("keep".utf8).write(to: kept)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.jpg.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a.jpg.json"), withDestinationURL: kept)
        XCTAssertNotNil(try move(root, action: "delete", members: members).error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.jpg").path))
        XCTAssertEqual(try String(contentsOf: kept), "keep")
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.jpg.json"))
        let current = try entries(root).filter { $0.name == "a.jpg" }
        XCTAssertNil(try move(root, action: "delete", members: current).error)
        XCTAssertEqual(try entries(root).map(\.name), ["keep.jpg"])
    }
    func testDeleteReportsPartialFailureWithoutCreatingRecoveryFiles() throws {
        let root = try fixture()
        let script = FrameRemoteHelper.script.replacingOccurrences(of: "os.unlink(name,dir_fd=d)",
            with: "if deleted: raise PermissionError('fixture permission denied')\n            os.unlink(name,dir_fd=d)")
        var input = BridgeAssetInput(action: "delete", root: root.path); input.members = try entries(root)
        let result = try call(input, script: script)
        XCTAssertTrue(result.error?.contains("already deleted:") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["a.jpg.json"])
    }
    func testTransportExecutesOnlyFixedProgramWithJSONOnStdin() async throws {
        let root = try fixture(), wrapper = root.appendingPathComponent("ssh-fixture")
        // A disposable SSH executable stand-in; never opens a host.
        try Data("#!/bin/sh\nfor last do :; done\nexec /bin/sh -c \"$last\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let service = SFTPRemoteFileService(connectionSharing: false, sshExecutableURL: wrapper)
        defer { service.shutdown() }
        let server = RemoteServer(id: UUID(), name: "Fixture", sshHost: "fixture.invalid", additionalArguments: [])
        let result = try await service.frameAsset(server: server, input: BridgeAssetInput(action: "list", root: root.path))
        XCTAssertEqual(Set(result.entries?.map(\.name) ?? []), ["a.jpg", "a.jpg.json", "ssh-fixture"])
    }
    func testVideoPosterAndMetadataWithoutOriginalTransfer() throws {
        guard ProcessInfo.processInfo.environment["FRAME_HELPER_PYTHON"] != nil,
              FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else {
            throw XCTSkip("Requires local ffmpeg and configured helper Python.")
        }
        let root = try fixture(), movie = root.appendingPathComponent("video.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=640x360:d=1", "-c:v", "mpeg4", movie.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        var input = BridgeAssetInput(action: "preview", root: root.path)
        input.members = try entries(root).filter { $0.name == "video.mp4" }; input.pixels = 512
        let result = try call(input)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.metadata?["Dimensions"], "640 × 360")
        XCTAssertNotNil(result.metadata?["Duration"])
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(result.image))).pixelsWide, 512)
    }
}
