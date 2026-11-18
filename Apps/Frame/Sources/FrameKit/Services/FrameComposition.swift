import AppKit
import Combine
import Composition
import HouseStyle
import PreviewSupport
import SwiftData

/// One WebKit document renderer follows the selection in either world.
@MainActor
final class DocumentRendererOwner {
    let client: any RemoteAssetServing
    private var current: DocumentRenderer?
    init(client: any RemoteAssetServing) { self.client = client }
    var renderer: DocumentRenderer {
        if let current { return current }
        let renderer = DocumentRenderer(client: client); current = renderer; return renderer
    }
    func stop() { current?.stop() }
    func suspendRemote(_ message: String) { current?.suspendRemote(message) }
    func finishStopping() async { await current?.finishStopping() }
}

@MainActor
public struct FramePreviewContent {
    public var image: CGImage?
    public var document: DocumentRenderer?
    public var playback: PlaybackController?
}

@MainActor
public struct FramePreviewRequest {
    let photo: PhotoItem
    var pixels = 2048
    var priority = 0
    var location: DocumentLocation?
    var path: String?
    var downloadOriginal = true
}

// MARK: - Preview features, written once and mounted in both worlds

/// The registries the shell opens previews through. They outlive any feature; registrations come and go.
@MainActor
struct FramePreviewRegistries {
    let previews = FrameComposition.Registry()
    let remotePreviews = FrameComposition.Registry()
    let playback = FrameComposition.Registry()
    let remotePlayback = FrameComposition.Registry()
}

/// Offers this world's registries. In the remote realm it exists only while there is a session.
struct PreviewHostFeature: Feature {
    @Constant var registries: FramePreviewRegistries
    @Need(FrameServices.MediaSource.self) var source
    @Offer(FrameServices.Previews.self) var previews
    @Offer(FrameServices.PlaybackPreviews.self) var playback

    func run(_ context: FeatureContext) async throws {
        previews.set(source.isRemote ? registries.remotePreviews : registries.previews)
        playback.set(source.isRemote ? registries.remotePlayback : registries.playback)
    }
}

/// Image and video-poster previews. The descriptor is configuration: a new limit reloads this format alone.
struct MediaPreviewFormat: Feature {
    let descriptor: PreviewDescriptor
    @Need(FrameServices.Previews.self) var previews
    @Need(FrameServices.Thumbnails.self) var thumbnails
    @Need(FrameServices.MediaSource.self) var source

    func run(_ context: FeatureContext) async throws {
        let remote = source.isRemote, thumbnails = thumbnails
        try previews.register(descriptor, in: context) { request in
            try context.checkActive()
            guard (request.photo.remote != nil) == remote else { throw CompositionError("Preview location changed.") }
            let image = try await thumbnails.image(request.photo, pixels: request.pixels, priority: request.priority)
            try Task.checkCancellation()
            guard let image else { throw CompositionError("Preview unavailable for this file.") }
            return PreviewResource(FramePreviewContent(image: image))
        }
    }
}

/// Markdown, HTML, text and other-file previews in the shared document renderer.
struct DocumentPreviewFormat: Feature {
    let descriptor: PreviewDescriptor
    @Need(FrameServices.Previews.self) var previews
    @Need(FrameServices.Documents.self) var documents
    @Need(FrameServices.LocalAccess.self) var access
    @Need(FrameServices.MediaSource.self) var source

    func run(_ context: FeatureContext) async throws {
        let remote = source.isRemote, documents = documents, access = access, limit = Int(descriptor.maximumBytes)
        try previews.register(descriptor, in: context) { request in
            try context.checkActive()
            guard (request.photo.remote != nil) == remote else { throw CompositionError("Preview location changed.") }
            guard let location = request.location, let path = request.path else { throw CompositionError("Choose a document location.") }
            let lease: FrameLocalAccessLease?
            if case .local(let root) = location { lease = try access.acquire([root], rootID: request.photo.rootID) }
            else { lease = nil }
            let renderer = documents.renderer
            renderer.show(path: path, location: location, maximumBytes: limit)
            return PreviewResource(FramePreviewContent(document: renderer), stop: { renderer.stop() },
                                   dispose: { await renderer.finishStopping(); lease?.release() })
        }
    }
}

/// Video playback through the shared player. A remote video is fetched through the session first.
struct VideoPlaybackFormat: Feature {
    let descriptor: PreviewDescriptor
    @Need(FrameServices.PlaybackPreviews.self) var registry
    @Need(FrameServices.Playback.self) var playback
    @Need(FrameServices.MediaSource.self) var source

    func run(_ context: FeatureContext) async throws {
        let remote = source.isRemote, session = source.session, playback = playback
        try registry.register(descriptor, in: context) { request in
            try context.checkActive()
            guard request.photo.format.isVideo, (request.photo.remote != nil) == remote else {
                throw CompositionError("Choose a video at this location to play.")
            }
            try playback.prepare(request.photo, downloadOriginal: request.downloadOriginal) { photo in
                try context.checkActive()
                let local = try await session?.resolve(photo, allowVideo: true) ?? photo
                try context.checkActive()
                return local
            }
            return PreviewResource(FramePreviewContent(playback: playback.controller), stop: { playback.stop() },
                                   dispose: { await playback.finishStopping() })
        }
    }
}

struct DocumentsFeature: Feature {
    @Constant var owner: DocumentRendererOwner
    @Offer(FrameServices.Documents.self) var documents

    func run(_ context: FeatureContext) async throws {
        let owner = owner
        try context.effect("document renderer", cancel: { owner.stop() }) { await owner.finishStopping() }
        documents.set(owner)
    }
}

/// The remote world's source: the session, while there is one.
struct RemoteSourceFeature: Feature {
    @Need(FrameServices.RelaySession.self) var session
    @Offer(FrameServices.MediaSource.self) var source

    func run(_ context: FeatureContext) async throws { source.set(.remote(session)) }
}

// MARK: - Composition root

@MainActor
public final class FrameComposition: ObservableObject {
    public typealias Registry = FilePreviewRegistry<FramePreviewRequest, FramePreviewContent>
    public let runtime = FeatureRuntime()
    public let files: FrameFileFeatures
    public let remoteLibrary = FrameRemoteLibrary()
    public let library: FrameLibraryFeatures
    let preferences: FramePreferences
    public let client: ComposedRemoteAccess
    public let link: FrameRemoteLink
    public let media: FrameMediaFeatures
    public let transfers: RemoteTransferState
    public let playback: PlaybackController
    private let registries = FramePreviewRegistries()
    public var registry: Registry { registries.previews }
    public var remoteRegistry: Registry { registries.remotePreviews }
    var playbackRegistry: Registry { registries.playback }
    var remotePlaybackRegistry: Registry { registries.remotePlayback }
    private let documentOwner: DocumentRendererOwner
    public var documentRenderer: DocumentRenderer { documentOwner.renderer }
    private let remoteAccess: ServicePort<FrameRemoteAccess>
    private let fixedSession: FixedRemoteSession?
    private var additionalFeatures: [FeatureNode]
    private var excluded: Set<String> = []
    private var started = false
    private var reported: Set<String> = []
    public var enabledKinds: Set<String> {
        let document = preferences.store.value
        return Set(Self.descriptors.filter { document.preview($0.id).enabled }.map(\.id))
    }
    /// True while a session is available to the shell, from RelayBar or from a fixture.
    public var remoteAvailable: Bool { remoteAccess.value != nil }
    private var documentSession: PreviewSession<FramePreviewContent>?
    private var playbackSession: PreviewSession<FramePreviewContent>?
    private var documentTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var documentRetirement: Task<Void, Never>?
    private var playbackRetirement: Task<Void, Never>?
    private var documentGeneration = UUID()
    private var playbackGeneration = UUID()
    private var closing = false
    private var shutdownTask: Task<Void, Never>?
    private var shutdownComplete = false
    private var observations: Set<AnyCancellable> = []
    public var errorHandler: ((Error) -> Void)?
    public var remoteDidWithdraw: ((String) -> Void)?

    public static let descriptors: [PreviewDescriptor] = [
        .init(id: "image", title: "Images", extensions: ["jpg", "jpeg", "png"], maximumBytes: Int64.max),
        .init(id: "video", title: "Video", extensions: ["mp4", "mov", "m4v"], maximumBytes: Int64.max),
        .init(id: "markdown", title: "Markdown", extensions: ["md", "markdown"], maximumBytes: 10 * 1_024 * 1_024),
        .init(id: "html", title: "HTML", extensions: ["html", "htm"], maximumBytes: 10 * 1_024 * 1_024),
        .init(id: "text", title: "Text files", extensions: PhotoFormat.textExtensions, maximumBytes: 10 * 1_024 * 1_024),
        .init(id: "file", title: "Other files", extensions: ["*"], maximumBytes: 10 * 1_024 * 1_024)
    ]

    /// `remoteSession` mounts a fixed session in place of the RelayBar link (fixtures, verification bundle).
    public init(link: FrameRemoteLink? = nil, preferencesURL: URL? = nil, connectAutomatically: Bool = false,
                fileFeatures: FrameFileFeatures? = nil, mediaFeatures: FrameMediaFeatures? = nil,
                libraryFeatures: FrameLibraryFeatures? = nil, remoteSession: FixedRemoteSession? = nil,
                additionalFeatures: [FeatureNode] = []) {
        files = fileFeatures ?? FrameFileFeatures()
        library = libraryFeatures ?? FrameLibraryFeatures()
        media = mediaFeatures ?? FrameMediaFeatures()
        preferences = FramePreferences(url: preferencesURL)
        let transfers = RemoteTransferState()
        let link = link ?? FrameRemoteLink(automaticallyConnect: connectAutomatically, progress: { id, value in
            Task { @MainActor in transfers.messages[id] = value }
        })
        self.link = link; self.transfers = transfers
        fixedSession = remoteSession
        self.additionalFeatures = additionalFeatures
        remoteAccess = runtime.port(FrameServices.RemoteAccess.self)
        let client = ComposedRemoteAccess(link: link, access: remoteAccess)
        self.client = client
        playback = PlaybackController()
        documentOwner = DocumentRendererOwner(client: client)
        files.attach(runtime); library.attach(runtime); media.attach(runtime); remoteLibrary.attach(runtime)
        link.runtime = runtime
        // A late request must never reopen a composition that has shut down; only an explicit start does.
        link.ensureStarted = { [weak self] in
            guard let self, !closing else { throw CancellationError() }
            try await start()
        }
        link.didWithdraw = { [weak self] message in
            guard let self else { return }
            documentOwner.suspendRemote(message); playback.withdrawRemote()
            transfers.messages.removeAll()
            remoteDidWithdraw?(message)
        }
        // Views observe this object; it republishes when features, preferences or the link change.
        for change in [runtime.objectWillChange, preferences.store.objectWillChange, link.objectWillChange,
                       transfers.objectWillChange, files.objectWillChange] {
            change.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        // Paper Appearance is drawn by the shell, not run as a feature: the saved choice applies before the first
        // window, and each later choice applies at once.
        let saved = preferences.store.peek()?.plugins ?? preferences.store.value.plugins
        HousePalette.apply(PaperAppearance.form(saved))
        preferences.store.$value.dropFirst().map { PaperAppearance.form($0.plugins) }.removeDuplicates()
            .sink { HousePalette.apply($0) }.store(in: &observations)
        runtime.$statuses.sink { [weak self] in self?.report($0) }.store(in: &observations)
    }

    // MARK: Tree

    /// Thumbnails, metadata, the enabled preview formats and, while its plugin is on, Prompt Search:
    /// the same nodes at the root (this Mac) and inside the remote realm (RelayBar).
    private func mediaNodes(_ document: FramePreferenceDocument) -> [FeatureNode] {
        let operations = media.operations, registries = registries
        var nodes = [
            FeatureNode("thumbnails") { ThumbnailsFeature(operations: operations) },
            FeatureNode("metadata") { MetadataFeature(operations: operations) },
            FeatureNode("previews") { PreviewHostFeature(registries: registries) }
        ]
        for base in Self.descriptors where document.preview(base.id).enabled {
            let current = document.descriptor(base)
            if base.id == "image" || base.id == "video" {
                nodes.append(FeatureNode("preview.\(base.id)") { MediaPreviewFormat(descriptor: current) })
            } else {
                nodes.append(FeatureNode("preview.\(base.id)") { DocumentPreviewFormat(descriptor: current) })
            }
            if base.id == "video" { nodes.append(FeatureNode("playback.video") { VideoPlaybackFormat(descriptor: current) }) }
        }
        if document.plugins.isEnabled(FramePlugins.promptSearch) {
            nodes.append(FeatureNode("prompt-search") { PromptSearchFeature() })
        }
        return nodes
    }

    /// The whole tree, decided in one place from the preference document and whether the catalog is open.
    @FeatureTreeBuilder
    private func tree() -> [FeatureNode] {
        let document = preferences.store.value, files = files, library = library, link = link
        let operations = media.operations, player = playback, owner = documentOwner
        FeatureNode("access") { LocalAccessFeature(operations: library.accessOperations) }
        if let data = library.data {
            FeatureNode("library.catalog") { CatalogFeature(data: data) }
            FeatureNode("library.favorites") { FavoritesFeature(data: data) }
            FeatureNode("library.scanning") { ScanningFeature(data: data) }
        }
        FeatureNode("files.trash") { TrashFeature(operations: files.operations, history: files.history) }
        FeatureNode("files.archive") { ArchiveFeature(operations: files.operations) }
        FeatureNode("files.export") { ExportFeature(operations: files.operations) }
        FeatureNode("playback") { PlaybackFeature(controller: player) }
        FeatureNode("documents") { DocumentsFeature(owner: owner) }
        mediaNodes(document)

        if let fixedSession {
            FeatureNode("relay.link") { FixedSessionFeature(fixed: fixedSession) }
        } else if document.display.showsRemoteFolders {
            FeatureNode("relay.link") { RelayLinkFeature(link: link) }
        }
        FeatureNode("remote.access") { RemoteAccessFeature() }
        FeatureNode.realm("remote", isolating: FrameServices.isolatedInRemoteRealm) {
            FeatureNode("source") { RemoteSourceFeature() }
            mediaNodes(document)
            FeatureNode("metadata-helper") { HelperMetadataFeature(operations: operations) }
            FeatureNode("originals") { OriginalsFeature() }
            FeatureNode("library") { RemoteLibraryFeature() }
            FeatureNode("delete") { RemoteDeleteFeature() }
            FeatureNode("archive") { RemoteArchiveFeature() }
            FeatureNode("export") { RemoteExportFeature() }
        }
        additionalFeatures
    }

    /// Hands the runtime the current tree. Cheap when nothing changed.
    private func reconfigure() throws {
        link.setHidden(fixedSession == nil && !preferences.store.value.display.showsRemoteFolders)
        try runtime.set(tree().excluding(excluded))
    }

    private func apply() async throws {
        try reconfigure()
        await runtime.settled()
    }

    private func report(_ statuses: [FeatureStatus]) {
        // A feature that failed or is stuck is told to the user once, with its reason.
        for status in statuses {
            let reason: String
            switch status.phase {
            case .failed(let message): reason = message
            case .stuck(let message): reason = message
            default: reported.remove(status.id); continue
            }
            if reported.insert(status.id).inserted, !closing { errorHandler?(CompositionError("\(status.id): \(reason)")) }
        }
    }

    public static func kind(for photo: PhotoItem) -> String {
        if photo.format.isImage { return "image" }
        if photo.format.isVideo { return "video" }
        switch photo.format { case .markdown: return "markdown"; case .html: return "html"; case .text: return "text"; default: return "file" }
    }

    // MARK: Lifecycle

    public func start() async throws {
        if closing {
            guard shutdownComplete else { throw CancellationError() }
            closing = false; shutdownComplete = false; shutdownTask = nil
        }
        guard !started else { return }
        try preferences.load()
        try await apply()
        started = true
    }

    func bindLibrary(_ model: ModelContext) async throws {
        guard !closing else { throw CancellationError() }
        try library.bind(model)
        // Read identifiers only for the one-time layout import; bookmarks stay in SwiftData.
        let roots = try model.fetch(FetchDescriptor<LibraryRootRecord>()).map(\.id)
        try await start()
        try await apply()
        try preferences.importDocumentLayouts(roots: roots)
    }

    func updatePreferences(_ change: @escaping @MainActor (inout FramePreferenceValues) -> Void) async throws {
        guard !closing else { throw CancellationError() }
        try await start()
        let shown = preferences.store.value.display.showsRemoteFolders
        try preferences.store.update { change(&$0.display) }
        try reconfigure()
        if preferences.store.value.display.showsRemoteFolders != shown { await runtime.settled() }
    }

    func connectLibrary() async throws -> FrameRemoteLibraryFeature {
        guard !closing else { throw CancellationError() }
        try await start()
        if !remoteLibrary.isAvailable { try await link.connect() }
        guard let feature = remoteLibrary.feature, feature.isActive else { throw CompositionError("Remote library is unavailable.") }
        return feature
    }

    /// Leaves the named features (full ids, such as `remote/thumbnails`) out of the tree.
    func setExcluded(_ ids: Set<String>) async throws {
        guard !closing else { throw CancellationError() }
        try await start()
        excluded = ids
        try await apply()
    }

    /// Adds or removes one feature from the excluded set.
    func exclude(_ id: String, _ isExcluded: Bool = true) async throws {
        var ids = excluded
        if isExcluded { ids.insert(id) } else { ids.remove(id) }
        try await setExcluded(ids)
    }

    /// The feature's status while it is running, otherwise nil.
    func active(_ id: String) -> FeatureStatus? { runtime.status(id).flatMap { $0.isActive ? $0 : nil } }

    func setAdditionalFeatures(_ features: [FeatureNode]) async throws {
        guard !closing else { throw CancellationError() }
        try await start()
        additionalFeatures = features
        try await apply()
    }

    // MARK: Settings

    private func updatePreview(_ kind: String, _ change: (inout FramePreferenceDocument.Preview) -> Void) async throws {
        guard !closing else { throw CancellationError() }
        try await start()
        try preferences.store.update { document in
            var preview = document.preview(kind)
            change(&preview)
            document.previews[kind] = preview
        }
        try await apply()
    }

    public func setEnabled(_ kind: String, _ enabled: Bool) async throws {
        guard Self.descriptors.contains(where: { $0.id == kind }) else { throw CompositionError("Unknown preview format.") }
        try await updatePreview(kind) { $0.enabled = enabled }
    }

    public func maximumBytes(_ kind: String) -> Int64? {
        guard Self.descriptors.contains(where: { $0.id == kind }) else { return nil }
        return preferences.store.value.preview(kind).maximumBytes
    }

    public func setMaximumBytes(_ kind: String, _ bytes: Int64) async throws {
        guard let descriptor = Self.descriptors.first(where: { $0.id == kind }), bytes > 0, bytes <= descriptor.maximumBytes else {
            throw CompositionError("Invalid preview size limit.")
        }
        try await updatePreview(kind) { $0.maximumBytes = bytes }
    }

    /// Whether a plugin is on, after the user's override of its default.
    /// Before the document has loaded, the saved choice is read directly, so a Plugins window shown first agrees with
    /// the colours Paper Appearance already applied.
    public func isPluginEnabled(_ plugin: PluginDescriptor) -> Bool {
        (preferences.store.peek() ?? preferences.store.value).plugins.isEnabled(plugin)
    }

    /// Stores the choice, then applies the tree: the plugin's features load or unload and nothing else reloads.
    public func setPlugin(_ plugin: PluginDescriptor, enabled: Bool) async throws {
        guard FramePlugins.all.contains(plugin) else { throw CompositionError("Unknown plugin.") }
        guard !closing else { throw CancellationError() }
        try await start()
        try preferences.store.update { $0.plugins.set(plugin, enabled: enabled) }
        try await apply()
    }

    private func identity(_ photo: PhotoItem, feature: String, kind: String) -> String {
        let id = (photo.remote == nil ? "" : "remote/") + feature
        let generation = runtime.status(id).flatMap { $0.isActive ? "\($0.generation)" : nil } ?? "unavailable"
        return "\(enabledKinds.contains(kind)):\(maximumBytes(kind) ?? 0):\(photo.remote == nil || remoteAvailable):\(generation)"
    }

    /// Changes whenever the feature serving this file's preview is replaced, so the view reloads.
    public func settingsID(for photo: PhotoItem) -> String {
        let kind = Self.kind(for: photo)
        return identity(photo, feature: "preview.\(kind)", kind: kind)
    }

    public func playbackSettingsID(for photo: PhotoItem) -> String {
        identity(photo, feature: "playback.video", kind: "video")
    }

    // MARK: Opening previews

    public func image(_ photo: PhotoItem, pixels: Int, priority: Int = 0) async throws -> PreviewSession<FramePreviewContent> {
        guard !closing else { throw CancellationError() }
        try await start()
        if photo.remote != nil, !remoteAvailable { throw CompositionError(link.message) }
        return try await (photo.remote == nil ? registry : remoteRegistry).open(kind: Self.kind(for: photo), bytes: photo.fileSize, request: FramePreviewRequest(photo: photo, pixels: pixels, priority: priority))
    }

    public func showDocument(_ photo: PhotoItem, path: String, location: DocumentLocation) {
        guard !closing else { return }
        stopDocument()
        let token = documentGeneration, previous = documentRetirement
        documentTask = Task { [self] in
            await previous?.value
            do {
                guard documentGeneration == token else { return }
                try await start(); try Task.checkCancellation()
                if photo.remote != nil, !remoteAvailable { try await link.connect() }
                let session = try await (photo.remote == nil ? registry : remoteRegistry).open(kind: Self.kind(for: photo), bytes: photo.fileSize,
                    request: FramePreviewRequest(photo: photo, location: location, path: path))
                guard documentGeneration == token, !Task.isCancelled, !session.isClosed else { await session.close(); return }
                documentSession = session
                session.onClose = { [weak self, weak session] in
                    guard let self, let session, documentSession === session else { return }
                    documentSession = nil
                    if photo.remote != nil, !remoteAvailable { session.content.document?.suspendRemote(link.message) }
                    else { session.content.document?.clearPreview() }
                }
            } catch is CancellationError {} catch {
                if documentGeneration == token {
                    if photo.remote != nil, !remoteAvailable {
                        documentOwner.renderer.connectionUnavailable(error.localizedDescription, location: location, path: path)
                    } else { documentOwner.renderer.showFailure(error.localizedDescription) }
                    errorHandler?(error)
                }
            }
        }
    }

    public func preparePlayback(_ photo: PhotoItem, downloadOriginal: Bool = true) {
        guard !closing else { return }
        clearPlayback()
        guard photo.format.isVideo else { return }
        let token = playbackGeneration, previous = playbackRetirement
        playbackTask = Task {
            await previous?.value
            do {
                guard playbackGeneration == token else { return }
                try await start(); try Task.checkCancellation()
                if photo.remote != nil, !remoteAvailable { try await link.connect() }
                let session = try await (photo.remote == nil ? playbackRegistry : remotePlaybackRegistry).open(kind: "video", bytes: photo.fileSize,
                    request: FramePreviewRequest(photo: photo, downloadOriginal: downloadOriginal))
                guard playbackGeneration == token, !Task.isCancelled, !session.isClosed else { await session.close(); return }
                playbackSession = session
            } catch is CancellationError {} catch { if playbackGeneration == token { errorHandler?(error) } }
        }
    }

    public func clearPlayback() {
        let task = playbackTask, previous = playbackRetirement
        playbackGeneration = UUID(); task?.cancel(); playbackTask = nil
        let old = playbackSession; playbackSession = nil; old?.invalidate(); playback.clear()
        playbackRetirement = Task {
            await previous?.value; await task?.value; await old?.close(); await playback.finishStopping()
        }
    }

    public func stopDocument() {
        let task = documentTask, previous = documentRetirement
        documentGeneration = UUID(); task?.cancel(); documentTask = nil
        let old = documentSession; documentSession = nil; old?.invalidate(); documentOwner.stop()
        documentRetirement = Task {
            await previous?.value; await task?.value; await old?.close(); await documentOwner.finishStopping()
        }
    }

    public func retireSelection() async {
        stopDocument(); clearPlayback()
        await documentRetirement?.value; await playbackRetirement?.value
    }

    /// Unloads every feature. Never waits past the deadline; whatever did not finish is logged.
    public func stop() async {
        if let shutdownTask { await shutdownTask.value; return }
        closing = true
        stopDocument(); clearPlayback()
        let document = documentRetirement, playback = playbackRetirement
        let task = Task {
            let unfinished = await runtime.shutdown(deadline: .seconds(20))
            for status in unfinished { NSLog("Frame: %@ did not finish unloading: %@", status.id, "\(status.phase)") }
            await document?.value; await playback?.value
            started = false
            shutdownComplete = true
        }
        shutdownTask = task
        await task.value
    }
}
