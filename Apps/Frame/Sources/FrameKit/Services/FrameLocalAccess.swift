import Composition
import Foundation

@MainActor
struct FrameSecurityScopeOperations {
    var start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
}

/// An explicit borrow. The resource owner outlives this borrow; callers release only
/// after their worker/player/renderer has finished using its files.
@MainActor
final class FrameLocalAccessLease {
    private var releaseBody: (() -> Void)?
    init(_ release: @escaping () -> Void) { releaseBody = release }
    func release() { let body = releaseBody; releaseBody = nil; body?() }
}

@MainActor
private final class LocalRootAccess {
    let id = UUID()
    let url: URL
    let path: String
    private let operations: FrameSecurityScopeOperations
    private let scoped: Bool
    private var references = 1
    private var accepting = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var didClose: (() -> Void)?
    init(url: URL, operations: FrameSecurityScopeOperations) {
        self.url = url; path = url.resolvingSymlinksInPath().standardizedFileURL.path
        self.operations = operations; scoped = operations.start(url)
    }
    func borrow() throws {
        guard accepting else { throw CancellationError() }
        references += 1
    }
    func release() {
        precondition(references > 0)
        references -= 1
        guard references == 0 else { return }
        if scoped { operations.stop(url) }
        let completion = didClose; didClose = nil; completion?()
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func retire() {
        guard accepting else { return }
        accepting = false; release()
    }
    func finish() async {
        retire()
        if references > 0 { await withCheckedContinuation { waiters.append($0) } }
    }
}

/// Owns the original security-scoped URLs, independently of UI selection and
/// normalized display paths. A retired root closes only after every borrow ends.
@MainActor
final class FrameLocalAccessFeature {
    private weak var context: FeatureContext?
    private let operations: FrameSecurityScopeOperations
    private var roots: [UUID: LocalRootAccess] = [:]
    private var current: LocalRootAccess?
    private var currentID: UUID?
    private var remembered: [String: URL] = [:]
    private var retiredPaths: Set<String> = []
    private var retiredRootIDs: Set<UUID> = []
    private var closed = false
    var isActive: Bool { !closed && context?.isActive == true }
    init(_ context: FeatureContext, operations: FrameSecurityScopeOperations) { self.context = context; self.operations = operations }
    private func check() throws -> FeatureContext {
        guard let context, !closed else { throw CancellationError() }
        try context.checkActive(); return context
    }
    private func own(_ url: URL) throws -> LocalRootAccess {
        let context = try check(), root = LocalRootAccess(url: url, operations: operations)
        let token: UUID
        do { token = try context.effect(cancel: { root.retire() }) { await root.finish() } }
        catch { root.retire(); throw error }
        roots[root.id] = root
        root.didClose = { [weak self, weak context] in
            self?.roots.removeValue(forKey: root.id)
            context?.effects.completed(token)
        }
        return root
    }
    func activate(_ url: URL, rootID: UUID) throws {
        _ = try check()
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if currentID == rootID, current?.path == path { return }
        let root = try own(url)
        closeRoot()
        current = root; currentID = rootID
        remembered[path] = url
    }
    func closeRoot() {
        let old = current
        if let currentID { retiredRootIDs.insert(currentID) }
        current = nil; currentID = nil
        if let old { retiredPaths.insert(old.path); old.retire() }
    }
    func authorizedURL(for root: URL) throws -> URL {
        _ = try check()
        return remembered[root.resolvingSymlinksInPath().standardizedFileURL.path] ?? root
    }
    func acquire(_ urls: [URL], rootID: UUID? = nil, allowRetired: Bool = false) throws -> FrameLocalAccessLease {
        _ = try check()
        if !allowRetired, let rootID, retiredRootIDs.contains(rootID), rootID != currentID { throw CancellationError() }
        var borrowed: [UUID: LocalRootAccess] = [:]
        do {
            for url in urls {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                let root: LocalRootAccess
                let temporary: Bool
                if let current, Self.contains(path, in: current.path) {
                    root = current; temporary = false
                } else {
                    // A newly authorized remote cache file may share a local folder's
                    // ancestor path without belonging to that retired library root.
                    let retiredIdentity = rootID.map { retiredRootIDs.contains($0) } ?? true
                    guard allowRetired || !retiredIdentity || !retiredPaths.contains(where: { Self.contains(path, in: $0) }) else { throw CancellationError() }
                    let saved = remembered.keys.filter { Self.contains(path, in: $0) }.max { $0.count < $1.count }
                    let authorized = saved.flatMap { remembered[$0] } ?? url
                    let authorizedPath = authorized.resolvingSymlinksInPath().standardizedFileURL.path
                    root = try borrowed.values.first { $0.path == authorizedPath } ?? own(authorized)
                    temporary = true
                }
                if borrowed[root.id] == nil { try root.borrow(); borrowed[root.id] = root }
                if temporary { root.retire() }
            }
        } catch {
            for root in borrowed.values { root.release() }
            throw error
        }
        return FrameLocalAccessLease { for root in borrowed.values { root.release() } }
    }
    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    func stop() {
        closed = true; closeRoot()
        for root in Array(roots.values) { root.retire() }
    }
    func shutdown() async {
        stop()
        for root in Array(roots.values) { await root.finish() }
        remembered.removeAll(); retiredPaths.removeAll(); retiredRootIDs.removeAll()
    }
}

/// The local world's source: bookmarked folders on this Mac.
struct LocalAccessFeature: Feature {
    @Constant var operations: FrameSecurityScopeOperations
    @Offer(FrameServices.LocalAccess.self) var access
    @Offer(FrameServices.MediaSource.self) var source

    func run(_ context: FeatureContext) async throws {
        let feature = FrameLocalAccessFeature(context, operations: operations)
        try context.effect("local access", cancel: { feature.stop() }) { await feature.shutdown() }
        access.set(feature)
        source.set(.local(feature))
    }
}
