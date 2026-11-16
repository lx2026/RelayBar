import Composition
import Foundation
import XCTest

@MainActor
final class PreferenceStoreTests: XCTestCase {
    private struct Prefs: Codable, Equatable {
        var retryLimit = 10
        var previews: [String: Bool] = ["markdown": true]
        var limit: Int64 = 9_007_199_254_740_993
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testFirstRunImportsLegacyValuesOnceAndLaterRunsIgnoreThem() throws {
        let url = try directory().appendingPathComponent("preferences.json")
        let first = PreferenceStore(url: url, initial: Prefs())
        try first.load(importing: { Prefs(retryLimit: 3) })
        XCTAssertEqual(first.value.retryLimit, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let second = PreferenceStore(url: url, initial: Prefs())
        try second.load(importing: { XCTFail("Legacy values were read twice"); return Prefs(retryLimit: 99) })
        XCTAssertEqual(second.value.retryLimit, 3)
        XCTAssertEqual(second.value.limit, 9_007_199_254_740_993, "Large integers survive exactly")
    }

    func testUpdateValidatesSavesWithABackupThenPublishes() throws {
        let url = try directory().appendingPathComponent("preferences.json")
        let store = PreferenceStore(url: url, initial: Prefs()) { value in
            guard (0...100).contains(value.retryLimit) else { throw CompositionError("Invalid retry limit.") }
        }
        XCTAssertThrowsError(try store.update { $0.retryLimit = 1 }, "Edits before loading are rejected")
        try store.load()
        var published: [Int] = []
        let observation = store.$value.dropFirst().sink { published.append($0.retryLimit) }
        defer { observation.cancel() }

        try store.update { $0.retryLimit = 4 }
        try store.update { $0.retryLimit = 4 }
        XCTAssertThrowsError(try store.update { $0.retryLimit = 500 })
        XCTAssertEqual(published, [4])
        XCTAssertEqual(store.value.retryLimit, 4)

        let reopened = PreferenceStore(url: url, initial: Prefs())
        try reopened.load()
        XCTAssertEqual(reopened.value.retryLimit, 4)
        let previous = PreferenceStore(url: try XCTUnwrap(store.backupURL), initial: Prefs())
        try previous.load()
        XCTAssertEqual(previous.value.retryLimit, 10)
    }

    func testFailedSaveChangesNothingDownstream() throws {
        let folder = try directory()
        let store = PreferenceStore(url: folder.appendingPathComponent("preferences.json"), initial: Prefs())
        try store.load()
        var published = 0
        let observation = store.$value.dropFirst().sink { _ in published += 1 }
        defer { observation.cancel() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try store.update { $0.retryLimit = 2 })
        XCTAssertEqual(store.value.retryLimit, 10)
        XCTAssertEqual(published, 0)
    }

    func testDocumentFromANewerVersionIsPreservedAndNeverApplied() throws {
        let url = try directory().appendingPathComponent("preferences.json")
        let future = Data(#"{"version":99,"preferences":{"somethingNew":true}}"#.utf8)
        try future.write(to: url)
        let store = PreferenceStore(url: url, initial: Prefs())
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(store.isLoaded)
        XCTAssertThrowsError(try store.update { $0.retryLimit = 1 })
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testCorruptDocumentIsReportedNotReplaced() throws {
        let url = try directory().appendingPathComponent("preferences.json")
        try Data("not json".utf8).write(to: url)
        let store = PreferenceStore(url: url, initial: Prefs())
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    }

    func testAFailedSaveActivatesNothing() async throws {
        struct SideEffect: Feature {
            @Constant var log: Log
            @MainActor func run(_ context: FeatureContext) async throws { log.counts["activations", default: 0] += 1 }
        }
        struct Switch: Codable, Equatable { var enabled = false }
        let folder = try directory(), log = Log(), runtime = FeatureRuntime()
        let store = PreferenceStore(url: folder.appendingPathComponent("preferences.json"), initial: Switch())
        try store.load()
        let observation = store.$value.sink { value in
            try? runtime.set(value.enabled ? [FeatureNode("side-effect") { SideEffect(log: log) }] : [])
        }
        defer { observation.cancel() }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try store.update { $0.enabled = true })
        await runtime.settled()
        XCTAssertEqual(log.count("activations"), 0)
        XCTAssertFalse(store.value.enabled)
    }
}
