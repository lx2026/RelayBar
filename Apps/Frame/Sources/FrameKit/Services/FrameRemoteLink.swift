import AppKit
import BridgeProtocol
import Combine
import Composition
import Foundation

/// Discovery and the authenticated session, owned by one feature. While that feature runs, the link
/// probes RelayBar, fills the session slot when a v6 catalog authenticates, and clears it the moment
/// the session ends. Everything remote depends on that slot; nothing outside drives it.
@MainActor
public final class FrameRemoteLink: ObservableObject {
    public enum State: Equatable {
        case idle, connecting, connected, hidden
        case unavailable(String)
    }

    /// One connection to RelayBar: how to send on it and how to end it.
    public struct Connection: Sendable {
        public let transport: RelayRemoteClient.Transport
        public let close: @Sendable () -> Void
        /// True when the connection reports its own end, so liveness needs no periodic request.
        public let reportsEnd: Bool
        public init(transport: @escaping RelayRemoteClient.Transport, close: @escaping @Sendable () -> Void = {}, reportsEnd: Bool = false) {
            self.transport = transport; self.close = close; self.reportsEnd = reportsEnd
        }
    }
    /// Makes a connection. `ended` is called once if RelayBar ends it.
    public typealias Connector = @Sendable (_ ended: @escaping @Sendable (BridgeError) -> Void) -> Connection

    /// One load of the link feature.
    @MainActor
    private final class Active {
        let context: FeatureContext
        let slot: Slot<any RemoteAssetServing>
        var client: RelayRemoteClient?
        var connection: Connection?
        /// Identifies one authenticated session, so a late result from an earlier one is ignored.
        var session = UUID()
        var probe: Task<Void, Never>?
        var retiring: [(client: RelayRemoteClient, connection: Connection?)] = []
        var releases: [UUID: Task<Void, Never>] = [:]
        init(context: FeatureContext, slot: Slot<any RemoteAssetServing>) { self.context = context; self.slot = slot }
    }

    @Published public private(set) var state: State = .idle
    public var isConnected: Bool { state == .connected && active?.client != nil }
    public var message: String {
        switch state {
        case .hidden: return "Remote folders are hidden. Enable them in Frame Settings."
        case .connecting: return "Connecting to RelayBar…"
        case .unavailable(let message): return message
        default: return "Open RelayBar, then retry the remote connection."
        }
    }
    public var didWithdraw: ((String) -> Void)?
    private let connector: Connector
    private let automaticallyConnect: Bool
    private let progress: @Sendable (String, String?) -> Void
    private let sharedRoot: @Sendable () throws -> URL
    private var active: Active?
    private var hidden = false
    weak var runtime: FeatureRuntime?
    /// Starts the composition if a view asks to connect before it has.
    var ensureStarted: (@MainActor () async throws -> Void)?

    /// With no transport, each session is one authenticated connection to RelayBar's socket.
    /// A supplied transport (fixtures) has no connection behind it and is checked periodically instead.
    public init(transport: RelayRemoteClient.Transport? = nil,
                automaticallyConnect: Bool = false,
                sharedRoot: @escaping @Sendable () throws -> URL = { try FrameBridgeEnvironment.root() },
                progress: @escaping @Sendable (String, String?) -> Void = { _, _ in }) {
        if let transport { connector = { _ in Connection(transport: transport) } }
        else { connector = Self.socket() }
        self.automaticallyConnect = automaticallyConnect; self.progress = progress
        self.sharedRoot = sharedRoot
    }

    public init(connector: @escaping Connector, automaticallyConnect: Bool = false,
                sharedRoot: @escaping @Sendable () throws -> URL = { try FrameBridgeEnvironment.root() },
                progress: @escaping @Sendable (String, String?) -> Void = { _, _ in }) {
        self.connector = connector; self.automaticallyConnect = automaticallyConnect; self.progress = progress
        self.sharedRoot = sharedRoot
    }

    /// One `BridgeChannel` per session. The peer is verified once, when the connection opens.
    public static func socket(_ url: URL? = nil, verifyPeer: (@Sendable (Int32) throws -> Void)? = nil) -> Connector {
        { ended in
            let channel = verifyPeer.map { BridgeChannel(socketURL: url, verifyPeer: $0, onClose: ended) }
                ?? BridgeChannel(socketURL: url, onClose: ended)
            return Connection(transport: { try await channel.exchange($0) }, close: { channel.close() }, reportsEnd: true)
        }
    }

    /// Presentation only: whether the feature exists is decided by the tree.
    func setHidden(_ hidden: Bool) {
        self.hidden = hidden
        if hidden { if active == nil { state = .hidden } }
        else if state == .hidden { state = .idle }
    }

    // MARK: Feature body

    fileprivate func run(_ context: FeatureContext, slot: Slot<any RemoteAssetServing>) throws {
        let active = Active(context: context, slot: slot)
        try context.effect("relay session", cancel: { [weak self] in self?.detach(active) }) {
            // The link unloads after everything that used its session, so the clients can be released here.
            for retired in active.retiring { await retired.client.shutdown(); retired.connection?.close() }
            active.retiring.removeAll()
        }
        self.active = active
        state = .idle
        let center = NSWorkspace.shared.notificationCenter
        let quit = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == FrameBridgeEnvironment.relayBundle else { return }
            MainActor.assumeIsolated { self?.withdraw("RelayBar quit. Open it, then retry.") }
        }
        try context.effect("relay quit observer") { center.removeObserver(quit) }
        try context.task("relay liveness") { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                // A connection that reports its own end needs no periodic request while it is up.
                if isConnected, self.active?.connection?.reportsEnd == true { continue }
                if automaticallyConnect || state != .idle { await check() }
            }
        }
    }

    /// The link feature itself is being withdrawn: hidden in Settings, or the app is closing.
    private func detach(_ active: Active) {
        guard self.active === active else { return }
        let wasConnected = isConnected
        if let client = active.client { active.retiring.append((client, active.connection)) }
        active.client = nil; active.connection = nil; active.session = UUID()
        self.active = nil
        state = hidden ? .hidden : .idle
        if wasConnected { didWithdraw?(message) }
    }

    // MARK: Session

    public func connect() async throws {
        guard !hidden else { throw BridgeError(message) }
        try await ensureStarted?()
        guard active != nil else { throw BridgeError(message) }
        if !isConnected { await check() }
        await runtime?.settled()
        guard isConnected else { throw BridgeError(message) }
    }

    /// Ends the session at once. Every remote feature stops admitting work before this returns;
    /// the client is released after they have finished unloading.
    public func withdraw(_ message: String) {
        guard let active else {
            if !hidden { state = .unavailable(message) }
            return
        }
        let old = active.client, connection = active.connection, wasConnected = old != nil && state == .connected
        active.client = nil; active.connection = nil; active.session = UUID()
        state = hidden ? .hidden : .unavailable(message)
        if wasConnected { didWithdraw?(message) }
        active.slot.clear()
        guard let old else { return }
        active.retiring.append((old, connection))
        let id = UUID()
        active.releases[id] = try? active.context.task("retire relay session") {
            await active.slot.drained()
            await old.shutdown()
            connection?.close()
            active.retiring.removeAll { $0.client === old }
            active.releases[id] = nil
        }
    }

    /// Returns once remote features have finished loading or unloading and every ended session's client is released.
    public func settle() async {
        await runtime?.settled()
        while let release = active?.releases.values.first {
            await release.value
            await runtime?.settled()
        }
    }

    private func check() async {
        guard let active, active.context.isActive else { return }
        if let probe = active.probe { await probe.value; return }
        let token = active.session, existing = active.client
        // A new session gets its own connection; RelayBar ending it ends the session at once.
        let connection = existing == nil ? connector { [weak self] error in
            Task { @MainActor in self?.failed(error, session: token) }
        } : nil
        let client = existing ?? RelayRemoteClient(transport: connection!.transport, sharedRoot: sharedRoot, progress: progress,
            sessionFailure: { [weak self] error in await self?.failed(error, session: token) })
        if existing == nil { state = .connecting }
        let task = try? active.context.task("relay probe") { [weak self] in
            do {
                _ = try await client.catalog()
                guard let self, self.active === active, active.context.isActive, active.session == token, !Task.isCancelled else {
                    if existing == nil { await client.shutdown(); connection?.close() }
                    return
                }
                if existing == nil {
                    active.client = client; active.connection = connection
                    state = .connected
                    active.slot.set(client)
                }
            } catch {
                if let self, self.active === active, active.session == token, !Task.isCancelled {
                    withdraw(error.localizedDescription)
                }
                if existing == nil { await client.shutdown(); connection?.close() }
            }
        }
        active.probe = task
        await task?.value
        active.probe = nil
    }

    private func failed(_ error: BridgeError, session token: UUID) {
        guard active?.session == token else { return }
        withdraw(error.localizedDescription)
    }
}

/// Owns discovery and the session. Present while remote folders are shown.
struct RelayLinkFeature: Feature {
    @Constant var link: FrameRemoteLink
    @Offer(FrameServices.RelaySession.self) var session

    func run(_ context: FeatureContext) async throws { try link.run(context, slot: session) }
}

/// A session supplied directly instead of through RelayBar, for fixtures and the verification bundle.
@MainActor
public final class FixedRemoteSession {
    let value: any RemoteAssetServing
    fileprivate var slot: Slot<any RemoteAssetServing>?
    public init(_ value: any RemoteAssetServing) { self.value = value }
    /// Ends the session as RelayBar would: every remote feature stops admitting work before this returns.
    public func withdraw() { slot?.clear() }
    public func restore() { slot?.set(value) }
}

struct FixedSessionFeature: Feature {
    @Constant var fixed: FixedRemoteSession
    @Offer(FrameServices.RelaySession.self) var session

    func run(_ context: FeatureContext) async throws {
        fixed.slot = session
        session.set(fixed.value)
    }
}

/// The shell's access to the session. A call made through it is owned by this feature, so the
/// session is not released while the call is in flight, and a result that arrives after
/// withdrawal is never returned.
@MainActor
final class FrameRemoteAccess {
    private let context: FeatureContext
    private let session: any RemoteAssetServing
    init(_ context: FeatureContext, session: any RemoteAssetServing) { self.context = context; self.session = session }
    func perform<Result>(_ body: @escaping @MainActor (any RemoteAssetServing) async throws -> Result) async throws -> Result {
        let session = session
        return try await context.perform("remote call") { try await body(session) }
    }
}

struct RemoteAccessFeature: Feature {
    @Need(FrameServices.RelaySession.self) var session
    @Offer(FrameServices.RemoteAccess.self) var access

    func run(_ context: FeatureContext) async throws { access.set(FrameRemoteAccess(context, session: session)) }
}

/// UI and pure readers receive this facade, never the authenticated client.
@MainActor
public final class ComposedRemoteAccess: RemoteAssetServing {
    private let link: FrameRemoteLink
    private let access: ServicePort<FrameRemoteAccess>
    init(link: FrameRemoteLink, access: ServicePort<FrameRemoteAccess>) { self.link = link; self.access = access }

    private func use<Result>(_ body: @escaping @MainActor (any RemoteAssetServing) async throws -> Result) async throws -> Result {
        guard let access = access.value else { throw BridgeError(link.message, sessionFailure: .unavailable) }
        return try await access.perform(body)
    }
    public func catalog() async throws -> BridgeResponse {
        if access.value == nil { try await link.connect() }
        return try await use { try await $0.catalog() }
    }
    public func handoff(_ nonce: UUID) async throws -> BridgeHandoff {
        if access.value == nil { try await link.connect() }
        return try await use { try await $0.handoff(nonce) }
    }
    public func list(source: BridgeSource, path: String) async throws -> ScanResult {
        try await use { try await $0.list(source: source, path: path) }
    }
    public func rememberOpen(source: BridgeSource, path: String) async throws {
        try await use { try await $0.rememberOpen(source: source, path: path) }
    }
    public func resolve(_ photo: PhotoItem, includeCompanions: Bool, allowVideo: Bool, priority: Int) async throws -> PhotoItem {
        if photo.remote == nil { return photo }
        return try await use { try await $0.resolve(photo, includeCompanions: includeCompanions, allowVideo: allowVideo, priority: priority) }
    }
    public func documentStats(source: BridgeSource, root: String, paths: [String]) async throws -> [BridgeEntry] {
        try await use { try await $0.documentStats(source: source, root: root, paths: paths) }
    }
    public func cachedMedia(_ photo: PhotoItem) async -> PhotoItem? {
        try? await use { await $0.cachedMedia(photo) }
    }
    public func companionText(_ photo: PhotoItem) async -> [BridgeCompanionText] {
        (try? await use { await $0.companionText(photo) }) ?? []
    }
    public func pin(_ photo: PhotoItem?) async {
        try? await use { await $0.pin(photo) }
    }
    public func preview(_ photo: PhotoItem, pixels: Int, priority: Int) async throws -> BridgeAssetResult {
        try await use { try await $0.preview(photo, pixels: pixels, priority: priority) }
    }
    public func mutate(_ photo: PhotoItem, action: String, root: String) async throws -> UUID? {
        try await use { try await $0.mutate(photo, action: action, root: root) }
    }
    public func delete(_ photos: [PhotoItem], root: String) async -> [FileActionFailure] {
        do { return try await use { await $0.delete(photos, root: root) } }
        catch { return photos.map { FileActionFailure(photo: $0, reason: error.localizedDescription) } }
    }
    public func archivedAssets(source: BridgeSource, root: String) async throws -> [PhotoItem] {
        try await use { try await $0.archivedAssets(source: source, root: root) }
    }
}
