import Combine
import Foundation

/// What the user chose, and nothing about how features are wired. An edit is validated, written
/// atomically with the previous file kept beside it, and only then published; a failed write
/// changes nothing downstream.
@MainActor
public final class PreferenceStore<Value: Codable & Equatable>: ObservableObject {
    private struct Envelope: Codable {
        var version: Int
        var preferences: Value
    }
    private struct Header: Decodable { var version: Int }

    @Published public private(set) var value: Value
    public private(set) var isLoaded = false
    public let url: URL?
    public var backupURL: URL? { url?.appendingPathExtension("previous") }
    private let version: Int
    private let validate: (Value) throws -> Void

    public init(url: URL?, initial: Value, version: Int = 1, validate: @escaping (Value) throws -> Void = { _ in }) {
        self.url = url; value = initial; self.version = version; self.validate = validate
    }

    /// Reads the saved document, or on first run stores `legacy()` (or the initial value).
    /// A document written by a newer version is left untouched and nothing is published.
    public func load(importing legacy: () throws -> Value? = { nil }) throws {
        guard !isLoaded else { return }
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.version == version else {
                throw CompositionError("Preferences were saved by a different version (\(header.version)).")
            }
            let saved = try JSONDecoder().decode(Envelope.self, from: data).preferences
            try validate(saved)
            value = saved
        } else {
            let first = try legacy() ?? value
            try validate(first)
            try write(first)
            value = first
        }
        isLoaded = true
    }

    /// What `load` would publish, read without loading: the loaded value, the saved document, or nil when there is no
    /// usable saved document yet. Lets an app honour a choice before its first window, ahead of loading.
    public func peek() -> Value? {
        if isLoaded { return value }
        guard let url, let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode(Header.self, from: data))?.version == version,
              let saved = try? JSONDecoder().decode(Envelope.self, from: data).preferences,
              (try? validate(saved)) != nil else { return nil }
        return saved
    }

    public func update(_ change: (inout Value) throws -> Void) throws {
        guard isLoaded else { throw CompositionError("Preferences are not loaded.") }
        var next = value
        try change(&next)
        guard next != value else { return }
        try validate(next)
        try write(next)
        value = next
    }

    private func write(_ next: Value) throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: version, preferences: next))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let backupURL, FileManager.default.fileExists(atPath: url.path) {
            try Data(contentsOf: url).write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
