import Composition
import SwiftData
import XCTest
@testable import FrameKit

@MainActor
final class FileFeatureTests: XCTestCase {
    func testFileFeaturesNeedNoSavedWiringAndPreviewChoicesPersist() async throws {
        let storage = try root().appendingPathComponent("preferences.json")
        let composition = FrameComposition(preferencesURL: storage)
        try await composition.start()
        XCTAssertTrue(composition.files.canTrash)
        XCTAssertTrue(composition.files.canArchive)
        XCTAssertTrue(composition.files.canExport)
        try await composition.setEnabled("html", false)
        XCTAssertFalse(composition.enabledKinds.contains("html"))
        // Leaving a feature out of this run is not a preference and is never written.
        try await composition.exclude("files.export")
        XCTAssertFalse(composition.files.canExport)
        let text = try String(contentsOf: storage, encoding: .utf8)
        for wiring in ["files.", "library.", "remote", "thumbnails", "relay"] { XCTAssertFalse(text.contains(wiring), wiring) }
        await composition.stop()
        let reopened = FrameComposition(preferencesURL: storage)
        try await reopened.start()
        XCTAssertTrue(reopened.files.canExport)
        XCTAssertTrue(reopened.files.canTrash)
        XCTAssertFalse(reopened.enabledKinds.contains("html"))
        await reopened.stop()
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FrameFiles-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func photos(_ root: URL, count: Int = 1) throws -> [PhotoItem] {
        for index in 0..<count { try Data("asset \(index)".utf8).write(to: root.appendingPathComponent("\(index).jpg")) }
        return try FileScanner.scan(rootURL: root, rootID: UUID()).photos
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Operation did not reach its synchronization point")
    }

    func testTrashWithdrawalJoinsReceiptAndReenabledFeatureCanUndo() async throws {
        let root = try root(), trash = try self.root(), photo = try XCTUnwrap(photos(root).first)
        let gate = FileWorkerGate()
        defer { gate.release() }
        var operations = FrameLocalFileOperations()
        operations.trash = { photos, progress in
            let result = await BatchTrash.move(photos, operation: { source in
                let destination = trash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }, progress: progress)
            gate.enter()
            return result
        }
        let files = FrameFileFeatures(operations: operations)
        let composition = FrameComposition(fileFeatures: files)
        try await composition.start()
        let feature = try XCTUnwrap(files.trash)
        let imageGeneration = composition.active("preview.image")?.generation
        let operation = Task { try await feature.move([photo], root: root, rootID: photo.rootID) { _ in } }
        try await waitFor { gate.entered }
        var retired = false
        let disable = Task {
            try await composition.exclude("files.trash", true)
            retired = true
        }
        try await waitFor { !feature.isActive }
        XCTAssertFalse(retired, "Withdrawal must await the already moved asset's recovery receipt")
        XCTAssertFalse(files.canTrash)
        XCTAssertTrue(files.canArchive)
        XCTAssertEqual(files.undoCount, 0)
        gate.release()
        try await disable.value
        let result = try await operation.value
        XCTAssertEqual(result.successes.count, 1)
        XCTAssertEqual(files.undoCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.url.path))
        do { _ = try await feature.move([photo], root: root, rootID: photo.rootID) { _ in }; XCTFail("Retired feature admitted work") }
        catch {}
        try await composition.exclude("files.trash", false)
        let restored = try await XCTUnwrap(files.trash).restoreLast()
        XCTAssertEqual(restored?.restored.map(\.id), [photo.id])
        XCTAssertEqual(files.undoCount, 0)
        XCTAssertEqual(try Data(contentsOf: photo.url), Data("asset 0".utf8))
        XCTAssertEqual(composition.active("preview.image")?.generation, imageGeneration)
        try await composition.exclude("files.trash")
        XCTAssertFalse(files.canTrash)
        await composition.stop()
    }

    func testStoreShutdownWaitsForSubmittedExportAndRejectsLaterExport() async throws {
        let root = try root(), destination = try self.root().appendingPathComponent("copy.jpg")
        let photo = try XCTUnwrap(photos(root).first), gate = FileWorkerGate()
        defer { gate.release() }
        var operations = FrameLocalFileOperations()
        operations.copy = { source, destination, replacing in
            gate.enter()
            _ = try ExactCopyExporter.export(source: source, destination: destination, replacing: replacing)
        }
        let composition = FrameComposition(fileFeatures: FrameFileFeatures(operations: operations))
        let store = LibraryStore(previews: composition)
        let export = Task { await store.export(photo, to: ExportDestination(chosen: destination)) }
        try await waitFor { gate.entered }
        var stopped = false
        let shutdown = Task { await store.shutdown(); stopped = true }
        try await waitFor { !composition.files.canExport }
        XCTAssertFalse(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        gate.release()
        await shutdown.value
        await export.value
        XCTAssertTrue(stopped)
        XCTAssertFalse(store.isExporting)
        XCTAssertNil(store.notice, "A late receipt must not resurrect closing UI")
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: photo.url))
        let later = destination.deletingLastPathComponent().appendingPathComponent("later.jpg")
        await store.export(photo, to: ExportDestination(chosen: later))
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.path))
        XCTAssertTrue(composition.runtime.statuses.isEmpty)
    }

    func testArchiveCancellationStopsBetweenAssetsAndTrashToggleDoesNotDisableArchive() async throws {
        let root = try root(), photos = try photos(root, count: 3)
        let composition = FrameComposition()
        try await composition.start()
        try await composition.exclude("files.trash", true)
        let archive = try XCTUnwrap(composition.files.archive)
        let result = try await archive.apply(photos, root: root, restoring: false) { _ in archive.cancel() }
        XCTAssertEqual(result.processed, 1)
        XCTAssertTrue(result.failures.isEmpty)
        let archived = ArchiveService.load(root: root, rootID: photos[0].rootID).photos
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try FileScanner.scan(rootURL: root, rootID: photos[0].rootID).photos.filter { $0.archiveID == nil }.count, 2)
        let restored = try await archive.apply(archived, root: root, restoring: true) { _ in }
        XCTAssertEqual(restored.processed, 1)
        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertTrue(ArchiveService.load(root: root, rootID: photos[0].rootID).photos.isEmpty)
        try await composition.exclude("files.archive", true)
        do { _ = try await archive.apply(photos, root: root, restoring: false) { _ in }; XCTFail("Retired archive accepted a mutation") }
        catch {}
        XCTAssertTrue(composition.files.canExport)
        await composition.stop()
    }

    func testUndoWithdrawalWaitsForRestoreAndConsumesHistoryExactlyOnce() async throws {
        let root = try root(), trash = try self.root(), photo = try XCTUnwrap(photos(root).first)
        let gate = FileWorkerGate()
        defer { gate.release() }
        var operations = FrameLocalFileOperations()
        operations.trash = { photos, progress in
            await BatchTrash.move(photos, operation: { source in
                let destination = trash.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }, progress: progress)
        }
        operations.restore = { files in gate.enter(); return BatchTrash.restore(files) }
        let composition = FrameComposition(fileFeatures: FrameFileFeatures(operations: operations))
        try await composition.start()
        let feature = try XCTUnwrap(composition.files.trash)
        _ = try await feature.move([photo], root: root, rootID: photo.rootID) { _ in }
        let undo = Task { try await feature.restoreLast() }
        try await waitFor { gate.entered }
        var stopped = false
        let stop = Task { await composition.stop(); stopped = true }
        try await waitFor { !feature.isActive }
        XCTAssertFalse(stopped)
        XCTAssertEqual(composition.files.undoCount, 1)
        gate.release()
        await stop.value
        let restored = try await undo.value
        XCTAssertEqual(restored?.restored.count, 1)
        XCTAssertEqual(composition.files.undoCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.url.path))
        try await composition.start()
        let again = try await XCTUnwrap(composition.files.trash).restoreLast()
        XCTAssertNil(again)
        await composition.stop()
    }
}

/// Holds a filesystem transaction after admission, without relying on scheduler timing.
private final class FileWorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return didEnter }
    func enter() {
        condition.lock()
        defer { condition.unlock() }
        didEnter = true
        let deadline = Date().addingTimeInterval(15)
        while !released {
            if !condition.wait(until: deadline) { XCTFail("Worker gate timed out"); break }
        }
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
