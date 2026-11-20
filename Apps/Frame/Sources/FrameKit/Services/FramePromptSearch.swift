import PreviewSupport
import BridgeProtocol
import Composition
import Foundation

/// Prompt Search for one realm, written once for both worlds. On this Mac it reads the companion files Frame
/// pairs with each asset and a PNG's text chunks; remotely it asks the realm's session for companion text.
/// Text is cached, within a bound, for the life of this instance and is never written anywhere.
@MainActor
final class FramePromptSearchFeature {
    /// What changes when a file is edited or replaced: its size, its modification time and, on this Mac,
    /// its file identity.
    private struct Stamp: Hashable, Sendable {
        let size: Int64
        let modified: String
        var identity: String?
    }

    /// One asset's text is read again when the asset, or any of its companions, changes size or modification
    /// time, or a companion is added, removed or renamed.
    private struct TextKey: Hashable, Sendable {
        let id: PhotoItem.ID
        let asset: Stamp
        let companions: [String: Stamp]

        init(_ photo: PhotoItem) {
            id = photo.id
            if let remote = photo.remote {
                asset = Stamp(size: photo.fileSize, modified: remote.entry.modified)
                let entries = remote.companions.map { ($0.name, Stamp(size: $0.size, modified: $0.modified)) }
                companions = Dictionary(entries, uniquingKeysWith: { first, _ in first })
            } else {
                asset = Stamp(size: photo.fileSize, modified: Self.modified(photo.modifiedAt), identity: photo.fileIdentifier)
                let files = photo.companions.map { file in
                    (file.url.lastPathComponent, Stamp(size: file.size, modified: Self.modified(file.modifiedAt), identity: file.identifier))
                }
                companions = Dictionary(files, uniquingKeysWith: { first, _ in first })
            }
        }

        private static func modified(_ date: Date?) -> String {
            date.map { String($0.timeIntervalSince1970) } ?? ""
        }
    }

    /// One asset's searchable text, its length for the cache bound, and whether every companion could be read.
    private struct AssetText: Sendable {
        let key: TextKey
        let text: String
        let length: Int
        let isComplete: Bool

        init(_ photo: PhotoItem, parts: [String], isComplete: Bool) {
            key = TextKey(photo)
            text = parts.joined(separator: "\n")
            length = text.count
            self.isComplete = isComplete
        }
    }

    /// The most assets whose text is read at once.
    private static let concurrentReads = 6
    /// Companion characters searched per asset.
    private nonisolated static let textBudget = PreviewLimits.companionCharacters

    /// The most characters the cache holds. Adding text that would pass it empties the cache first.
    var cacheLimit = 16_000_000
    /// The characters the cache holds now.
    private(set) var cachedCharacters = 0
    private weak var context: FeatureContext?
    private let work: FrameFeatureWork
    private let client: (any RemoteFileReading)?
    private let remote: Bool
    private var texts: [TextKey: AssetText] = [:]
    var isActive: Bool { context?.isActive == true }

    init(_ context: FeatureContext, source: FrameMediaSource) {
        self.context = context
        remote = source.isRemote
        work = FrameFeatureWork(context, access: source.access)
        client = source.session.map { MediaRemoteAccess(context, session: $0) }
    }

    func cancel() {
        work.cancel()
    }

    /// The ids of the assets whose text contains every word of `query`. Text that is not cached yet is read,
    /// at most six assets at a time. The whole call is owned by the feature, so it is joined before the feature
    /// finishes unloading; a withdrawn feature or a cancelled caller gets an error, never a result.
    func matches(in photos: [PhotoItem], query: String) async throws -> Set<PhotoItem.ID> {
        guard let context else { throw CancellationError() }
        return try await context.perform("prompt search") { [self] in
            try await search(photos, query: query)
        }
    }

    /// The body of `matches`. Cached text is matched in one job; each new read is matched in its own work,
    /// so only ids and cache entries are kept while the search runs.
    private func search(_ photos: [PhotoItem], query: String) async throws -> Set<PhotoItem.ID> {
        guard photos.allSatisfy({ ($0.remote != nil) == remote }) else { throw CompositionError("Search location changed.") }
        let unread = photos.filter { texts[TextKey($0)] == nil }
        var found = try await matchCached(photos, query: query)
        var pending = unread.makeIterator()
        try await withThrowingTaskGroup(of: (entry: AssetText, matches: Bool).self) { group in
            for _ in 0..<Self.concurrentReads {
                guard let photo = pending.next() else { break }
                group.addTask { try await self.read(photo, query: query) }
            }
            while let read = try await group.next() {
                // A read that finished after its search was cancelled or its feature withdrawn is never kept.
                try Task.checkCancellation()
                try authorize()
                if read.matches {
                    found.insert(read.entry.key.id)
                }
                remember(read.entry)
                guard let photo = pending.next() else { continue }
                group.addTask { try await self.read(photo, query: query) }
            }
        }
        return found
    }

    /// Matches the assets whose text is cached, in one job off the main actor. The texts it was given are
    /// released when it returns.
    private func matchCached(_ photos: [PhotoItem], query: String) async throws -> Set<PhotoItem.ID> {
        let cached = photos.compactMap { photo in texts[TextKey(photo)].map { (id: photo.id, text: $0.text) } }
        return try await work.run(roots: []) {
            Set(cached.filter { Self.matches($0.text, query: query) }.map(\.id))
        }
    }

    /// True when `text` contains every whitespace-separated word of `query`, ignoring case and diacritics.
    /// Quotes and other punctuation are ordinary characters, and an empty query matches everything.
    nonisolated static func matches(_ text: String, query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func authorize() throws {
        guard let context else { throw CancellationError() }
        try context.checkActive()
    }

    /// Caches an asset's text unless one of its companions could not be read, so that asset is read again
    /// next time. Text longer than the whole bound is never cached.
    private func remember(_ read: AssetText) {
        guard read.isComplete, read.length <= cacheLimit else { return }
        cachedCharacters -= texts.removeValue(forKey: read.key)?.length ?? 0
        if cachedCharacters + read.length > cacheLimit {
            texts.removeAll()
            cachedCharacters = 0
        }
        texts[read.key] = read
        cachedCharacters += read.length
    }

    /// Reads one asset's text and matches it, as owned work: local folder access is held for the read, a remote
    /// read goes through the session, and the read is joined before the feature finishes unloading.
    private func read(_ photo: PhotoItem, query: String) async throws -> (entry: AssetText, matches: Bool) {
        let client = client
        let roots = remote ? [] : photo.fileMembers.map(\.url)
        return try await work.run(roots: roots, rootID: photo.rootID) {
            let entry = await Self.text(of: photo, client: client)
            return (entry, Self.matches(entry.text, query: query))
        }
    }

    /// The asset's file name followed by the text of each companion that could be read. A remote read that
    /// finished after its work was cancelled may be missing text, so it is incomplete.
    private nonisolated static func text(of photo: PhotoItem, client: (any RemoteFileReading)?) async -> AssetText {
        guard let client else { return localText(of: photo) }
        let companions = await client.companionText(photo).map(\.text)
        let interrupted = Task.isCancelled
        let isComplete = !interrupted && !companions.contains(where: isUnreadable)
        return AssetText(photo, parts: [photo.name] + companions.filter(isText), isComplete: isComplete)
    }

    /// The text of each companion file followed by a PNG's
    /// text chunks, within the budget. A companion that could not be read makes the result incomplete.
    private nonisolated static func localText(of photo: PhotoItem) -> AssetText {
        var remaining = textBudget
        var parts = [photo.name]
        var isComplete = true
        for file in photo.companions.prefix(PreviewLimits.companions) {
            guard remaining > 0 else { break }
            do {
                guard let whole = try SidecarReader.searchableText(file) else { continue }
                let text = PreviewLimits.companionText(whole, remaining: &remaining)
                parts.append(text)
            } catch {
                isComplete = false
            }
        }
        if photo.format == .png, remaining > 0 {
            do {
                let chunks = try PNGTextReader.read(from: photo.url)
                parts.append(String(chunks.values.joined(separator: "\n").prefix(remaining)))
            } catch {
                isComplete = false
            }
        }
        return AssetText(photo, parts: parts, isComplete: isComplete)
    }

    /// False for the sentences a session gives in place of a companion's text: one that could not be read,
    /// one too large, or one that is not text.
    private nonisolated static func isText(_ companion: String) -> Bool {
        !isUnreadable(companion) && companion != RelayRemoteClient.oversizedCompanionText
            && companion != SidecarReader.binaryCompanionText
    }

    /// True for the text given in place of a companion that could not be read; reading it again may succeed.
    private nonisolated static func isUnreadable(_ companion: String) -> Bool {
        companion.hasPrefix(RelayRemoteClient.unreadableCompanionPrefix)
    }
}

/// Prompt Search, written once against the realm's media source and mounted in both worlds while its plugin is on.
struct PromptSearchFeature: Feature {
    @Need(FrameServices.MediaSource.self) var source
    @Offer(FrameServices.PromptSearch.self) var search

    func run(_ context: FeatureContext) async throws {
        let feature = FramePromptSearchFeature(context, source: source)
        try context.effect("prompt search", cancel: { feature.cancel() }) {}
        search.set(feature)
    }
}
