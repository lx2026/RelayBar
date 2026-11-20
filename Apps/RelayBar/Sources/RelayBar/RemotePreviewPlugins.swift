import AppKit
import Composition
import PreviewSupport

extension RemoteFileEntry {
    var previewLimitError: RemoteFileError {
        if isPreviewableMarkdown { return .markdownTooLarge }
        if isPreviewableJSON { return .jsonTooLarge }
        if isPreviewableVideo { return .videoTooLarge }
        return .previewTooLarge
    }
}

@MainActor
struct RelayPreviewContent {
    var image: NSImage?
    var markdown: RemoteMarkdownDocument?
    var json: RemoteJSONDocument?
    var videoURL: URL?
    var html: RemoteHTMLRenderer?
}

@MainActor
struct RelayPreviewRequest {
    let entry: RemoteFileEntry
    let server: RemoteServer
    let root: String
    let progress: @Sendable (Int64) -> Void
    let preparingVideo: () -> Void
    let navigate: (RemoteFileEntry) -> Void
    let navigationError: (Error) -> Void
}

@MainActor
struct RelayPreviewDecoders {
    let image: (URL) async throws -> NSImage
    let markdown: (URL) async throws -> RemoteMarkdownDocument
    let json: (URL) async throws -> RemoteJSONDocument
    let video: (URL) async throws -> Void
}

/// The previews a Remote Files model opens. A composed window passes the registry its format
/// features fill; a standalone model registers every format with `allFormats`.
@MainActor
struct RemotePreviews {
    let registry: RemotePreviewPlugins.Registry
    let ready: () async throws -> Void
    let stop: () async -> Void

    func open(_ request: RelayPreviewRequest) async throws -> PreviewSession<RelayPreviewContent> {
        try await ready()
        // Transport/decoder-specific limits retain their existing user-facing errors.
        return try await registry.open(filename: request.entry.name, bytes: nil, request: request)
    }

    /// Every known format at its own limit. `stop` closes the registrations and their follow-up work.
    static func allFormats(service: any RemoteFileServing, decoders: RelayPreviewDecoders) throws -> RemotePreviews {
        let registry = RemotePreviewPlugins.Registry()
        let work = EffectScope()
        let registrations = try RemotePreviewPlugins.descriptors.map { descriptor in
            try registry.register(descriptor, isActive: { work.isOpen },
                render: RemotePreviewPlugins.renderer(descriptor, service: service, decoders: decoders, scope: work))
        }
        return RemotePreviews(registry: registry, ready: {}, stop: {
            for registration in registrations { registration.invalidate() }
            for registration in registrations { await registration.close() }
            await work.dispose()
        })
    }
}

/// The preview formats RelayBar knows, and how each one renders. A composed window mounts one
/// `RemotePreviewFormat` feature per enabled format; a standalone model uses `RemotePreviews.allFormats`.
enum RemotePreviewPlugins {
    typealias Registry = FilePreviewRegistry<RelayPreviewRequest, RelayPreviewContent>
    static let descriptors: [PreviewDescriptor] = [
        .init(id: "image", title: "Images", extensions: PreviewFileTypes.images(extended: true), maximumBytes: Int64(PreviewLimits.original)),
        .init(id: "markdown", title: "Markdown", extensions: PreviewFileTypes.markdown, maximumBytes: Int64(RemoteMarkdownDecoder.maximumByteCount)),
        .init(id: "json", title: "JSON", extensions: PreviewFileTypes.json, maximumBytes: Int64(RemoteJSONDecoder.maximumByteCount)),
        .init(id: "video", title: "Video", extensions: PreviewFileTypes.video, maximumBytes: RemoteVideoPreview.maximumByteCount),
        .init(id: "html", title: "HTML", extensions: PreviewFileTypes.html, maximumBytes: Int64(RemoteHTMLResources.documentLimit))
    ]

    /// The descriptor a format runs with, or an error if the configured limit is outside what the format allows.
    static func descriptor(_ kind: String, maximumBytes: Int64? = nil, extendedImages: Bool = true) throws -> PreviewDescriptor {
        guard let base = descriptors.first(where: { $0.id == kind }) else { throw CompositionError("Unknown preview format \(kind).") }
        let limit = maximumBytes ?? base.maximumBytes
        guard limit > 0, limit <= base.maximumBytes else { throw CompositionError("Invalid \(base.title) preview settings.") }
        return PreviewDescriptor(id: base.id, title: base.title, extensions: kind == "image" ? PreviewFileTypes.images(extended: extendedImages) : base.extensions, maximumBytes: limit)
    }

    /// Renders one format. `scope` owns follow-up work such as HTML link navigation.
    @MainActor
    static func renderer(_ current: PreviewDescriptor, service: any RemoteFileServing, decoders: RelayPreviewDecoders,
                         scope: EffectScope) -> @MainActor (RelayPreviewRequest) async throws -> PreviewResource<RelayPreviewContent> {
        { request in
            if current.id == "html" {
                return try await html(request, service: service, maximumBytes: Int(current.maximumBytes), scope: scope)
            }
            let url = try await service.preparePreview(server: request.server, entry: request.entry,
                maximumBytes: current.maximumBytes, progress: request.progress)
            do {
                try Task.checkCancellation()
                var result = RelayPreviewContent()
                switch current.id {
                case "image": result.image = try await decoders.image(url)
                case "markdown": result.markdown = try await decoders.markdown(url)
                case "json": result.json = try await decoders.json(url)
                case "video": request.preparingVideo(); try await decoders.video(url); result.videoURL = url
                default: throw CompositionError("Unknown preview renderer.")
                }
                try Task.checkCancellation()
                return PreviewResource(result, stop: { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) })
            } catch {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); throw error
            }
        }
    }

    @MainActor
    private static func html(_ request: RelayPreviewRequest, service: any RemoteFileServing, maximumBytes: Int,
                             scope: EffectScope) async throws -> PreviewResource<RelayPreviewContent> {
        let prefix = request.root == "/" ? "/" : request.root + "/"
        guard request.entry.path.hasPrefix(prefix) else { throw CompositionError("Document is outside the opened folder.") }
        let path = String(request.entry.path.dropFirst(prefix.count))
        let resources = RemoteHTMLResources(service: service, server: request.server, root: request.root)
        do {
            _ = try await resources.data(at: path, limit: maximumBytes)
            try Task.checkCancellation()
            let renderer = RemoteHTMLRenderer(resources: resources, path: path, documentLimit: maximumBytes)
            renderer.onNavigate = { target in
                _ = try? scope.task("html navigation") {
                    do {
                        guard scope.isOpen else { return }
                        let item = try await resources.entry(at: target)
                        guard scope.isOpen, !Task.isCancelled else { return }
                        request.navigate(RemoteFileEntry(name: item.name, path: item.path, kind: .file, size: item.size, modificationText: item.modified))
                    } catch { if scope.isOpen, !Task.isCancelled { request.navigationError(error) } }
                }
            }
            return PreviewResource(RelayPreviewContent(html: renderer), stop: { renderer.stop() }, dispose: { await renderer.close() })
        } catch { await resources.close(); throw error }
    }
}

/// One enabled preview format in a Remote Files window. Its limit is configuration: a new limit
/// reloads this format alone, closing the previews it produced.
struct RemotePreviewFormat: Feature {
    let kind: String
    let maximumBytes: Int64
    var extendedImages = true
    @Need(RelayServices.PreviewRegistry.self) var registry
    @Need(RelayServices.PreviewReader.self) var reader
    @Need(RelayServices.PreviewDecoders.self) var decoders

    func run(_ context: FeatureContext) async throws {
        let current = try RemotePreviewPlugins.descriptor(kind, maximumBytes: maximumBytes, extendedImages: extendedImages)
        try registry.register(current, in: context,
            render: RemotePreviewPlugins.renderer(current, service: reader, decoders: decoders, scope: context.effects))
    }
}
