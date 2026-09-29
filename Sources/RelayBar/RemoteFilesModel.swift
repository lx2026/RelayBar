import AppKit
import Foundation
import ImageIO

@MainActor
protocol RemoteFilePresenting: AnyObject {
    func chooseDestination(for entry: RemoteFileEntry) -> URL?
    func chooseUploadFile() -> URL?
    func confirmUploadReplacement(name: String) -> Bool
    func revealInFinder(_ destination: URL)
}

extension RemoteFilePresenting {
    func chooseUploadFile() -> URL? { nil }
    func confirmUploadReplacement(name: String) -> Bool { false }
}

@MainActor
final class AppKitRemoteFilePresenter: RemoteFilePresenting {
    func chooseDestination(for entry: RemoteFileEntry) -> URL? {
        if entry.isDirectory {
            let panel = NSOpenPanel()
            panel.title = "Choose where to download \(entry.name)"
            panel.prompt = "Choose"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let parent = panel.url else { return nil }

            let destination = parent.appendingPathComponent(entry.name, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                let alert = NSAlert()
                alert.messageText = "Replace “\(entry.name)”?"
                alert.informativeText =
                    "RelayBar will keep the existing folder until the new download finishes."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            }
            return destination
        }

        let panel = NSSavePanel()
        panel.title = "Download \(entry.name)"
        panel.prompt = "Download"
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func revealInFinder(_ destination: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func chooseUploadFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a file to upload"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func confirmUploadReplacement(name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace “\(name)” on the remote server?"
        alert.informativeText =
            "RelayBar stages the complete upload before replacing this named item. "
            + "Another remote client can still change that name during the final check."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum RemoteImageDecoder {
    private static let maximumSourceDimension = 100_000
    private static let maximumSourcePixels = 100_000_000
    private static let thumbnailDimension = 4_096

    static func decode(contentsOf url: URL) throws -> NSImage {
        let image = try decodeCGImage(contentsOf: url)
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    static func decodeCGImage(contentsOf url: URL) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0
        else {
            throw RemoteFileError.unsupportedImage
        }

        let pixelCount = width.multipliedReportingOverflow(by: height)
        guard
            !pixelCount.overflow,
            width <= maximumSourceDimension,
            height <= maximumSourceDimension,
            pixelCount.partialValue <= maximumSourcePixels
        else {
            throw RemoteFileError.imageDimensionsTooLarge
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else {
            throw RemoteFileError.unsupportedImage
        }
        return image
    }
}

/// Core Graphics images are immutable but do not carry Sendable annotations.
private struct DecodedRemoteImage: @unchecked Sendable {
    let value: CGImage
}

struct RemoteJSONDocument: Equatable, Sendable {
    let formattedText: String
}

enum RemoteJSONDecoder {
    static let maximumByteCount = 2 * 1_024 * 1_024

    static func load(contentsOf url: URL) async throws -> RemoteJSONDocument {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > maximumByteCount {
                throw RemoteFileError.jsonTooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumByteCount else {
                throw RemoteFileError.jsonTooLarge
            }

            let utf8: Data
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                utf8 = data.dropFirst(3)
            } else {
                utf8 = data
            }
            guard !utf8.contains(0), String(data: utf8, encoding: .utf8) != nil else {
                throw RemoteFileError.invalidJSONEncoding
            }

            let value: Any
            do {
                value = try JSONSerialization.jsonObject(
                    with: utf8,
                    options: [.fragmentsAllowed]
                )
            } catch {
                throw RemoteFileError.malformedJSON
            }

            let formatted: Data
            do {
                formatted = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
                )
            } catch {
                throw RemoteFileError.malformedJSON
            }
            guard let text = String(data: formatted, encoding: .utf8) else {
                throw RemoteFileError.invalidJSONEncoding
            }
            return RemoteJSONDocument(formattedText: text)
        }.value
    }
}

struct RemoteDirectoryCache {
    struct Key: Hashable {
        let connection: RemoteServer.ConnectionIdentity
        let path: String
    }

    private struct Snapshot {
        let entries: [RemoteFileEntry]
        let cost: Int
        var lastAccess: UInt64
    }

    let maximumEntryCount: Int
    private var snapshots: [Key: Snapshot] = [:]
    private(set) var entryCount = 0
    private var accessSequence: UInt64 = 0

    init(maximumEntryCount: Int = 20_000) {
        self.maximumEntryCount = maximumEntryCount
    }

    mutating func entries(
        for connection: RemoteServer.ConnectionIdentity,
        path: String
    ) -> [RemoteFileEntry]? {
        let key = Key(connection: connection, path: RemotePath.normalized(path))
        guard var snapshot = snapshots[key] else { return nil }
        accessSequence &+= 1
        snapshot.lastAccess = accessSequence
        snapshots[key] = snapshot
        return snapshot.entries
    }

    mutating func insert(
        _ entries: [RemoteFileEntry],
        for connection: RemoteServer.ConnectionIdentity,
        path: String
    ) {
        let key = Key(connection: connection, path: RemotePath.normalized(path))
        if let existing = snapshots.removeValue(forKey: key) {
            entryCount -= existing.cost
        }
        // Empty folders still consume cache metadata, so charge one unit and
        // keep the cache bounded even when every snapshot is empty.
        let cost = max(entries.count, 1)
        guard cost <= maximumEntryCount else { return }

        accessSequence &+= 1
        snapshots[key] = Snapshot(
            entries: entries,
            cost: cost,
            lastAccess: accessSequence
        )
        entryCount += cost

        while entryCount > maximumEntryCount {
            guard
                let oldest = snapshots.min(by: {
                    $0.value.lastAccess < $1.value.lastAccess
                })
            else {
                break
            }
            snapshots.removeValue(forKey: oldest.key)
            entryCount -= oldest.value.cost
        }
    }

    func contains(
        connection: RemoteServer.ConnectionIdentity,
        path: String
    ) -> Bool {
        snapshots[Key(connection: connection, path: RemotePath.normalized(path))] != nil
    }

    mutating func removeAll() {
        snapshots.removeAll()
        entryCount = 0
        accessSequence = 0
    }
}

@MainActor
final class RemoteFilesModel: ObservableObject {
    enum Screen: Equatable {
        case welcome
        case browser
        case preview
    }

    struct TransferPresentation: Identifiable {
        enum Phase: Equatable {
            case active
            case cancelling
            case completed
            case failed
            case cancelled
        }

        let id = UUID()
        let entry: RemoteFileEntry
        let destination: URL
        let connectionIdentity: RemoteServer.ConnectionIdentity
        let remoteDirectory: String
        var completedBytes: Int64
        let totalBytes: Int64?
        var phase: Phase
        var message: String?

        var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }
    }

    struct UploadPresentation: Identifiable {
        enum Phase: Equatable {
            case active
            case cancelling
            case completed
            case failed
            case cancelled
        }

        let id = UUID()
        let localFile: URL
        let replaceExisting: Bool
        let connectionIdentity: RemoteServer.ConnectionIdentity
        let remoteDirectory: String
        var phase: Phase
        var operationPhase: RemoteUploadPhase
        var completedBytes: Int64
        var totalBytes: Int64
        var isStagingComplete: Bool
        var message: String?

        var fraction: Double? {
            guard operationPhase == .staging else { return nil }
            if totalBytes == 0 { return isStagingComplete ? 1 : 0 }
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }

        var percentage: Int? {
            guard let fraction else { return nil }
            return min(Int(fraction * 100), isStagingComplete ? 100 : 99)
        }
    }

    struct PreviewProgressPresentation: Equatable {
        var completedBytes: Int64
        let totalBytes: Int64?
        var message: String

        var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }

        var percentage: Int? {
            guard let fraction else { return nil }
            return min(Int(fraction * 100), 99)
        }
    }

    struct DeletionPresentation: Identifiable {
        enum Phase: Equatable {
            case pendingUndo
            case active
            case failed
            case outcomeUnknown
        }

        let id = UUID()
        let entries: [RemoteFileEntry]
        var currentIndex: Int
        var completedCount: Int
        var phase: Phase
        var message: String?
        var undoDeadline: Date?

        var entry: RemoteFileEntry {
            entries[min(max(currentIndex, 0), entries.count - 1)]
        }

        init(
            entry: RemoteFileEntry,
            phase: Phase,
            message: String?
        ) {
            entries = [entry]
            currentIndex = 0
            completedCount = 0
            self.phase = phase
            self.message = message
        }

        init(
            entries: [RemoteFileEntry],
            phase: Phase,
            message: String?
        ) {
            precondition(!entries.isEmpty)
            self.entries = entries
            currentIndex = 0
            completedCount = 0
            self.phase = phase
            self.message = message
        }
    }

    @Published private(set) var screen: Screen = .welcome
    @Published private(set) var servers: [RemoteServer]
    @Published private(set) var recentLocations: [RemoteLocation]
    @Published var selectedServerID: UUID?
    @Published var remotePath = ""
    @Published private(set) var currentPath = ""
    @Published private(set) var pendingPath: String?
    @Published private(set) var entries: [RemoteFileEntry] = []
    @Published var selectedEntryID: String?
    @Published private(set) var isSelectingFiles = false
    @Published private(set) var selectedFileIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var previewEntry: RemoteFileEntry?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewMarkdown: RemoteMarkdownDocument?
    @Published private(set) var previewJSON: RemoteJSONDocument?
    @Published private(set) var previewVideoURL: URL?
    @Published private(set) var previewProgress: PreviewProgressPresentation?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var transfer: TransferPresentation?
    @Published private(set) var upload: UploadPresentation?
    @Published private(set) var deletion: DeletionPresentation?
    @Published private(set) var deletionAnnouncement: String?
    @Published private(set) var activeLocationID: UUID?
    @Published private(set) var failedLocationID: UUID?
    @Published private(set) var successfulOpenSequence = 0

    private let service: RemoteFileServing
    private let presenter: RemoteFilePresenting
    private let serverCatalog: RemoteServerCatalog
    private let imageDecoder: @Sendable (URL) throws -> CGImage
    private let markdownDecoder: (URL) async throws -> RemoteMarkdownDocument
    private let jsonDecoder: (URL) async throws -> RemoteJSONDocument
    private let videoValidator: (URL) async throws -> Void
    private let deletionUndoDelay: TimeInterval
    private var tunnels: [Tunnel]
    private var activeServer: RemoteServer?
    private var isFolderOpen = false
    private var navigationHistory: [String] = []
    private var directoryCache = RemoteDirectoryCache()
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var deletionTask: Task<Void, Never>?
    private var previewURL: URL?
    private var loadGeneration = UUID()
    private var previewGeneration = UUID()
    private var transferGeneration = UUID()
    private var uploadGeneration = UUID()
    private var deletionGeneration = UUID()
    private var pendingRootLocationID: UUID?
    private var deferredShutdownTask: Task<Void, Never>?
    private var shutdownCompletions: [@MainActor () -> Void] = []
    private var retryLoadRequest: (
        path: String,
        server: RemoteServer,
        previousPath: String?,
        isRefresh: Bool,
        popsHistory: Bool,
        selectionAfterLoad: String?,
        resolvesFile: Bool
    )?

    init(
        tunnels: [Tunnel],
        service: RemoteFileServing = SFTPRemoteFileService(),
        presenter: RemoteFilePresenting? = nil,
        imageDecoder: @escaping @Sendable (URL) throws -> CGImage =
            { try RemoteImageDecoder.decodeCGImage(contentsOf: $0) },
        markdownDecoder: @escaping (URL) async throws -> RemoteMarkdownDocument =
            { try await RemoteMarkdownDecoder.load(contentsOf: $0) },
        jsonDecoder: @escaping (URL) async throws -> RemoteJSONDocument =
            { try await RemoteJSONDecoder.load(contentsOf: $0) },
        videoValidator: @escaping (URL) async throws -> Void =
            { try await RemoteVideoPreview.validate(contentsOf: $0) },
        deletionUndoDelay: TimeInterval = 5,
        serverCatalog: RemoteServerCatalog? = nil
    ) {
        let catalog = serverCatalog ?? RemoteServerCatalog()
        let initialServers = catalog.servers(from: tunnels)
        servers = initialServers
        recentLocations = catalog.recentLocations(from: tunnels)
        selectedServerID = initialServers.first?.id
        self.service = service
        self.deletionUndoDelay = max(0, deletionUndoDelay)
        self.presenter = presenter ?? AppKitRemoteFilePresenter()
        self.serverCatalog = catalog
        self.imageDecoder = imageDecoder
        self.markdownDecoder = markdownDecoder
        self.jsonDecoder = jsonDecoder
        self.videoValidator = videoValidator
        self.tunnels = tunnels
    }

    var pathValidationMessage: String? {
        RemotePath.validationMessage(for: remotePath)
    }

    var canOpen: Bool {
        selectedServer != nil && pathValidationMessage == nil && !isLoading
            && !isRefreshing
            && !isTransferRunning
            && !isSelectingFiles
    }

    var presentedPath: String {
        pendingPath ?? currentPath
    }

    var canGoBack: Bool {
        guard !isTransferRunning, !isSelectingFiles else { return false }
        if screen == .preview {
            return true
        }
        guard screen == .browser else { return false }
        return !isLoading || pendingPath != nil
    }

    var backHelp: String {
        if isLoading, pendingPath != nil {
            return "Cancel opening this folder"
        }
        if isTransferRunning {
            return "Cancel the transfer before closing this folder"
        }
        return "Go back"
    }

    var selectedEntry: RemoteFileEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    var selectedFiles: [RemoteFileEntry] {
        entries.filter { selectedFileIDs.contains($0.id) }
    }

    var previewableEntries: [RemoteFileEntry] {
        entries.filter(\.isPreviewable)
    }

    var selectedServer: RemoteServer? {
        guard let selectedServerID else { return nil }
        return servers.first { $0.id == selectedServerID }
    }

    var canActivateLocation: Bool {
        !isLoading && !isRefreshing && !isTransferRunning && !isSelectingFiles
    }

    var canActivateEntry: Bool {
        !isLoading && !isTransferRunning && !isSelectingFiles
    }

    var canInteractWithFileList: Bool {
        !isLoading && !isTransferRunning
    }

    var canUpload: Bool {
        screen == .browser && isFolderOpen && !currentPath.isEmpty
            && !isLoading && !isTransferRunning && !isSelectingFiles
    }

    func canDelete(_ entry: RemoteFileEntry) -> Bool {
        entry.kind == .file
            && entries.contains(entry)
            && RemotePath.parent(of: entry.path) == RemotePath.normalized(currentPath)
            && activeServer != nil
            && deletion == nil
            && !isLoading
            && !isRefreshing
            && !isLoadingPreview
            && !isTransferRunning
            && !isSelectingFiles
    }

    var canDeletePreviewEntry: Bool {
        guard let previewEntry else { return false }
        return canDelete(previewEntry)
    }

    var canBeginFileSelection: Bool {
        screen == .browser
            && isFolderOpen
            && entries.contains(where: { $0.kind == .file })
            && !isLoading
            && !isRefreshing
            && !isTransferRunning
            && deletion == nil
            && !isSelectingFiles
    }

    var canDeleteSelectedFiles: Bool {
        guard
            screen == .browser,
            isSelectingFiles,
            !selectedFileIDs.isEmpty,
            selectedFiles.count == selectedFileIDs.count,
            activeServer != nil,
            deletion == nil,
            !isLoading,
            !isRefreshing,
            !isLoadingPreview,
            !isTransferRunning
        else { return false }
        let normalizedDirectory = RemotePath.normalized(currentPath)
        return selectedFiles.allSatisfy {
            $0.kind == .file
                && RemotePath.parent(of: $0.path) == normalizedDirectory
        }
    }

    var recentFolderLocations: [RemoteLocation] {
        Array(recentLocations.prefix(6))
    }

    func nestedLocations(
        for server: RemoteServer,
        excluding visibleLocations: [RemoteLocation]? = nil
    ) -> [RemoteLocation] {
        let visibleKeys = Set((visibleLocations ?? recentFolderLocations).map(\.key))
        return Array(
            recentLocations.lazy.filter {
                $0.server.connectionIdentity == server.connectionIdentity
                    && !visibleKeys.contains($0.key)
            }.prefix(3)
        )
    }

    func recentLocationCount(for server: RemoteServer) -> Int {
        recentLocations.count {
            $0.server.connectionIdentity == server.connectionIdentity
        }
    }

    func updateTunnels(_ tunnels: [Tunnel]) {
        self.tunnels = tunnels
        let selectedConnection = selectedServer?.connectionIdentity
        let updatedServers = serverCatalog.servers(from: tunnels)
        servers = updatedServers
        recentLocations = serverCatalog.recentLocations(from: tunnels)

        if
            let selectedConnection,
            let matchingServer = updatedServers.first(where: {
                $0.connectionIdentity == selectedConnection
            })
        {
            selectedServerID = matchingServer.id
        } else if screen == .welcome {
            selectedServerID = updatedServers.first?.id
        }
    }

    func servers(from source: RemoteServer.Source) -> [RemoteServer] {
        servers.filter { $0.source == source }
    }

    var canRemoveSelectedServer: Bool {
        guard let selectedServerID else { return false }
        return serverCatalog.isSavedServer(id: selectedServerID)
    }

    func addServer(name: String, sshHost: String) throws {
        let server = try serverCatalog.add(name: name, sshHost: sshHost)
        refreshServers(preferredConnection: server.connectionIdentity)
    }

    func removeSelectedServer() {
        guard let selectedServerID else { return }
        removeSavedServer(id: selectedServerID)
    }

    func isSavedServer(id: UUID) -> Bool {
        serverCatalog.isSavedServer(id: id)
    }

    func removeSavedServer(id: UUID) {
        serverCatalog.removeSavedServer(id: id)
        refreshServers(preferredConnection: nil)
    }

    func activate(_ location: RemoteLocation) {
        guard canActivateLocation else { return }
        let server = servers.first(where: {
            $0.connectionIdentity == location.server.connectionIdentity
        }) ?? location.server
        selectedServerID = server.id
        remotePath = location.path
        pendingRootLocationID = location.id
        startOpeningRemotePath(server: server, path: location.path)
    }

    func removeRecentLocation(id: UUID) {
        serverCatalog.removeRecentLocation(id: id)
        if activeLocationID == id { activeLocationID = nil }
        if failedLocationID == id { failedLocationID = nil }
        recentLocations = serverCatalog.recentLocations(from: tunnels)
    }

    func clearRecentLocations() {
        serverCatalog.clearRecentLocations()
        activeLocationID = nil
        failedLocationID = nil
        recentLocations = []
    }

    func removeFailedLocation() {
        guard let failedLocationID else { return }
        removeRecentLocation(id: failedLocationID)
        dismissLoadError()
    }

    func openRemotePath() {
        guard let server = selectedServer else {
            errorMessage = "Add or select an SSH server before opening remote files."
            return
        }
        guard pathValidationMessage == nil else {
            errorMessage = pathValidationMessage
            return
        }

        pendingRootLocationID = nil
        startOpeningRemotePath(server: server, path: remotePath)
    }

    private func startOpeningRemotePath(server: RemoteServer, path: String) {
        guard !isTransferRunning else { return }
        let path = RemotePath.normalized(path)
        let isSameConnection = activeServer?.connectionIdentity
            == server.connectionIdentity

        if
            isSameConnection,
            isFolderOpen,
            currentPath == path,
            screen == .browser || screen == .preview
        {
            if screen == .preview {
                retirePreviewForLocationChange()
                screen = .browser
            }
            navigationHistory = []
            remotePath = path
            if let location = serverCatalog.recordSuccessfulOpen(server, path: path) {
                activeLocationID = pendingRootLocationID ?? location.id
            }
            recentLocations = serverCatalog.recentLocations(from: tunnels)
            pendingRootLocationID = nil
            failedLocationID = nil
            errorMessage = nil
            successfulOpenSequence &+= 1
            refreshServers(preferredConnection: server.connectionIdentity)
            return
        }

        if isLoading, isSameConnection, pendingPath == path { return }

        clearFinishedTransfersForNavigation()
        loadTask?.cancel()
        loadGeneration = UUID()
        retirePreviewForLocationChange()
        if
            let activeServer,
            activeServer.connectionIdentity != server.connectionIdentity
        {
            service.shutdown()
            directoryCache.removeAll()
        }
        navigationHistory = []
        activeServer = server
        activeLocationID = nil
        failedLocationID = nil
        retryLoadRequest = nil
        currentPath = ""
        entries = []
        selectedEntryID = nil
        isFolderOpen = false
        screen = .welcome
        load(
            path: path,
            server: server,
            previousPath: nil,
            resolvesFile: true
        )
    }

    func refresh() {
        guard
            screen == .browser,
            let server = activeServer,
            !currentPath.isEmpty,
            !isLoading,
            !isRefreshing,
            !isTransferRunning,
            !isSelectingFiles
        else { return }
        load(path: currentPath, server: server, previousPath: nil, isRefresh: true)
    }

    func retryLastLoad() {
        guard let request = retryLoadRequest else {
            refresh()
            return
        }
        pendingRootLocationID = failedLocationID
        load(
            path: request.path,
            server: request.server,
            previousPath: request.previousPath,
            isRefresh: request.isRefresh,
            popsHistory: request.popsHistory,
            selectionAfterLoad: request.selectionAfterLoad,
            resolvesFile: request.resolvesFile
        )
    }

    func goBack() {
        if screen == .preview {
            closePreview()
            return
        }

        guard screen == .browser, canGoBack else { return }
        if isLoading, pendingPath != nil {
            loadTask?.cancel()
            loadGeneration = UUID()
            loadTask = nil
            pendingPath = nil
            isLoading = false
            errorMessage = nil
            retryLoadRequest = nil
            return
        }
        guard let previousPath = navigationHistory.last, let server = activeServer else {
            loadTask?.cancel()
            loadGeneration = UUID()
            loadTask = nil
            service.shutdown()
            directoryCache.removeAll()
            entries = []
            selectedEntryID = nil
            resetFileSelection()
            pendingPath = nil
            isLoading = false
            isRefreshing = false
            errorMessage = nil
            retryLoadRequest = nil
            activeServer = nil
            isFolderOpen = false
            activeLocationID = nil
            failedLocationID = nil
            pendingRootLocationID = nil
            transfer = nil
            upload = nil
            deletion = nil
            selectedServerID = servers.contains(where: { $0.id == selectedServerID })
                ? selectedServerID
                : servers.first?.id
            screen = .welcome
            return
        }
        load(
            path: previousPath,
            server: server,
            previousPath: nil,
            popsHistory: true,
            selectionAfterLoad: currentPath
        )
    }

    func dismissLoadError() {
        errorMessage = nil
        retryLoadRequest = nil
    }

    func select(_ entry: RemoteFileEntry) {
        if isSelectingFiles {
            toggleFileSelection(entry)
            return
        }
        selectedEntryID = entry.id
    }

    func beginFileSelection() {
        guard canBeginFileSelection else { return }
        selectedFileIDs = []
        isSelectingFiles = true
    }

    func cancelFileSelection() {
        guard isSelectingFiles, deletion == nil else { return }
        selectedFileIDs = []
        isSelectingFiles = false
    }

    func toggleFileSelection(_ entry: RemoteFileEntry) {
        guard
            isSelectingFiles,
            entry.kind == .file,
            entries.contains(entry),
            RemotePath.parent(of: entry.path) == RemotePath.normalized(currentPath),
            !isTransferRunning
        else { return }
        if selectedFileIDs.contains(entry.id) {
            selectedFileIDs.remove(entry.id)
        } else {
            selectedFileIDs.insert(entry.id)
        }
    }

    func activate(_ entry: RemoteFileEntry) {
        guard canActivateEntry else { return }
        select(entry)
        if entry.isDirectory {
            guard let server = activeServer else { return }
            load(path: entry.path, server: server, previousPath: currentPath)
        } else if entry.isPreviewable {
            preview(entry)
        } else {
            download(entry)
        }
    }

    func preview(_ entry: RemoteFileEntry) {
        guard
            entry.isPreviewable,
            !isTransferRunning,
            !isSelectingFiles,
            let server = activeServer
        else { return }
        select(entry)
        cleanupPreview()
        previewTask?.cancel()
        let generation = UUID()
        previewGeneration = generation
        previewEntry = entry
        previewImage = nil
        previewMarkdown = nil
        previewJSON = nil
        previewVideoURL = nil
        previewProgress = entry.isPreviewableVideo
            ? PreviewProgressPresentation(
                completedBytes: 0,
                totalBytes: entry.size,
                message: "Retrieving video…"
            )
            : nil
        isLoadingPreview = true
        errorMessage = nil
        screen = .preview

        previewTask = Task { [weak self] in
            guard let self else { return }
            var pendingPreviewURL: URL?
            defer {
                if let pendingPreviewURL {
                    try? FileManager.default.removeItem(
                        at: pendingPreviewURL.deletingLastPathComponent()
                    )
                }
            }
            do {
                let url: URL
                if entry.isPreviewableVideo {
                    url = try await service.preparePreviewWithProgress(
                        server: server,
                        entry: entry
                    ) { [weak self] completedBytes in
                        Task { @MainActor in
                            guard
                                let self,
                                self.previewGeneration == generation,
                                self.previewEntry?.id == entry.id,
                                self.isLoadingPreview
                            else { return }
                            let previous = self.previewProgress?.completedBytes ?? 0
                            self.previewProgress?.completedBytes = max(
                                previous,
                                min(completedBytes, entry.size ?? completedBytes)
                            )
                        }
                    }
                } else {
                    url = try await service.preparePreview(server: server, entry: entry)
                }
                pendingPreviewURL = url
                try Task.checkCancellation()
                guard previewGeneration == generation else { return }
                let image: NSImage?
                let markdown: RemoteMarkdownDocument?
                let json: RemoteJSONDocument?
                let videoURL: URL?
                if entry.isPreviewableImage {
                    image = try await decodeImage(at: url)
                    markdown = nil
                    json = nil
                    videoURL = nil
                } else if entry.isPreviewableMarkdown {
                    image = nil
                    markdown = try await markdownDecoder(url)
                    json = nil
                    videoURL = nil
                } else if entry.isPreviewableJSON {
                    image = nil
                    markdown = nil
                    json = try await jsonDecoder(url)
                    videoURL = nil
                } else {
                    image = nil
                    markdown = nil
                    json = nil
                    previewProgress?.message = "Preparing video…"
                    try await videoValidator(url)
                    videoURL = url
                }
                try Task.checkCancellation()
                guard previewGeneration == generation else { return }
                previewURL = url
                pendingPreviewURL = nil
                previewImage = image
                previewMarkdown = markdown
                previewJSON = json
                previewVideoURL = videoURL
                previewProgress = nil
                isLoadingPreview = false
            } catch is CancellationError {
                if previewGeneration == generation {
                    isLoadingPreview = false
                    previewProgress = nil
                }
            } catch {
                if previewGeneration == generation {
                    isLoadingPreview = false
                    previewProgress = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelPreviewLoading() {
        guard isLoadingPreview, previewEntry?.isPreviewableVideo == true else { return }
        previewTask?.cancel()
        previewGeneration = UUID()
        previewTask = nil
        isLoadingPreview = false
        previewProgress = nil
        errorMessage = "Video preview canceled."
    }

    func selectPreviewEntry(id: String?) {
        guard
            !isTransferRunning,
            let id,
            id != previewEntry?.id,
            let entry = previewableEntries.first(where: { $0.id == id })
        else {
            return
        }
        preview(entry)
    }

    @discardableResult
    func movePreviewSelection(by offset: Int) -> Bool {
        guard !isTransferRunning else { return false }
        let previewableEntries = previewableEntries
        guard
            !previewableEntries.isEmpty,
            let currentID = previewEntry?.id,
            let currentIndex = previewableEntries.firstIndex(where: {
                $0.id == currentID
            })
        else {
            return false
        }
        let targetIndex = min(
            max(currentIndex + offset, previewableEntries.startIndex),
            previewableEntries.index(before: previewableEntries.endIndex)
        )
        guard targetIndex != currentIndex else { return false }
        preview(previewableEntries[targetIndex])
        return true
    }

    func retryPreview() {
        guard let previewEntry else { return }
        preview(previewEntry)
    }

    func closePreview() {
        guard !isTransferRunning else { return }
        retirePreviewForLocationChange()
        errorMessage = nil
        screen = .browser
    }

    func download(_ entry: RemoteFileEntry) {
        guard !isTransferRunning, !isSelectingFiles else { return }
        guard let destination = presenter.chooseDestination(for: entry) else { return }
        startTransfer(entry: entry, destination: destination)
    }

    func beginUpload() {
        guard canUpload, let localFile = presenter.chooseUploadFile() else { return }
        let name = localFile.lastPathComponent
        let existing = entries.first { $0.name == name }
        if let existing, existing.kind != .file {
            errorMessage = RemoteFileError.unsupportedUploadTarget.localizedDescription
            return
        }
        let replaceExisting: Bool
        if existing != nil {
            guard presenter.confirmUploadReplacement(name: name) else { return }
            replaceExisting = true
        } else {
            replaceExisting = false
        }
        startUpload(localFile: localFile, replaceExisting: replaceExisting)
    }

    func cancelUpload() {
        guard upload?.phase == .active else { return }
        upload?.phase = .cancelling
        upload?.message = "Removing temporary file…"
        uploadTask?.cancel()
    }

    func retryUpload() {
        guard
            let upload,
            upload.phase == .failed || upload.phase == .cancelled,
            !isTransferRunning
        else {
            return
        }
        guard
            activeServer?.connectionIdentity == upload.connectionIdentity,
            RemotePath.normalized(currentPath) == upload.remoteDirectory
        else {
            self.upload = nil
            errorMessage = "Return to the original remote folder and choose Upload again."
            return
        }
        var replaceExisting = upload.replaceExisting
        if let existing = entries.first(where: {
            $0.name == upload.localFile.lastPathComponent
        }) {
            guard existing.kind == .file else {
                self.upload?.phase = .failed
                self.upload?.message = RemoteFileError.unsupportedUploadTarget
                    .localizedDescription
                return
            }
            if !replaceExisting {
                guard presenter.confirmUploadReplacement(name: existing.name) else {
                    return
                }
                replaceExisting = true
            }
        }
        self.upload = nil
        startUpload(
            localFile: upload.localFile,
            replaceExisting: replaceExisting
        )
    }

    func dismissUpload() {
        guard upload?.phase != .active, upload?.phase != .cancelling else { return }
        upload = nil
    }

    func deleteSelectedFiles() {
        guard canDeleteSelectedFiles else { return }
        startBatchDeletion(selectedFiles)
    }

    func delete(_ entry: RemoteFileEntry) {
        guard canDelete(entry), let server = activeServer else { return }
        let directory = currentPath
        let browserIndex = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
        let visibleImages = entries.filter(\.isPreviewableImage)
        let imageIndex = visibleImages.firstIndex(where: { $0.id == entry.id }) ?? 0
        let visiblePreviewables = previewableEntries
        let previewIndex = visiblePreviewables.firstIndex(where: { $0.id == entry.id }) ?? 0
        let deletedFromPreview = screen == .preview && previewEntry?.id == entry.id
        let generation = UUID()
        deletionGeneration = generation
        deletionAnnouncement = nil
        deletion = DeletionPresentation(
            entry: entry,
            phase: .pendingUndo,
            message: "Will delete \(entry.name)"
        )
        deletion?.undoDeadline = Date().addingTimeInterval(deletionUndoDelay)

        deletionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitForDeletionCommit(generation: generation)
                try await service.delete(server: server, entry: entry)
                try Task.checkCancellation()
                let refreshedEntries: [RemoteFileEntry]
                let isAuthoritativeRefresh: Bool
                do {
                    refreshedEntries = try await service.list(
                        server: server,
                        path: directory
                    )
                    isAuthoritativeRefresh = true
                } catch {
                    refreshedEntries = entries.filter { $0.id != entry.id }
                    isAuthoritativeRefresh = false
                }
                try Task.checkCancellation()
                guard deletionGeneration == generation else { return }
                applyAcknowledgedDeletion(
                    entry: entry,
                    refreshedEntries: refreshedEntries,
                    browserIndex: browserIndex,
                    imageIndex: imageIndex,
                    previewIndex: previewIndex,
                    deletedFromPreview: deletedFromPreview,
                    isAuthoritativeRefresh: isAuthoritativeRefresh,
                    server: server,
                    directory: directory
                )
            } catch {
                guard deletionGeneration == generation else { return }
                deletionTask = nil
                if error as? RemoteFileError == .deleteOutcomeUnknown {
                    do {
                        let refreshed = try await service.list(
                            server: server,
                            path: directory
                        )
                        guard deletionGeneration == generation else { return }
                        entries = refreshed
                        if !refreshed.contains(where: { $0.id == self.selectedEntryID }) {
                            selectedEntryID = nil
                        }
                        directoryCache.insert(
                            refreshed,
                            for: server.connectionIdentity,
                            path: directory
                        )
                        let stillPresent = refreshed.contains { $0.id == entry.id }
                        deletion?.phase = .failed
                        deletion?.message = error.localizedDescription
                            + (stillPresent
                                ? " The current listing still contains this path."
                                : " The current listing no longer contains this path.")
                    } catch {
                        guard deletionGeneration == generation else { return }
                        deletion?.phase = .outcomeUnknown
                        deletion?.message = RemoteFileError.deleteOutcomeUnknown
                            .localizedDescription
                            + " Refresh again before deleting another file."
                    }
                } else {
                    if let refreshed = try? await service.list(
                        server: server,
                        path: directory
                    ) {
                        guard deletionGeneration == generation else { return }
                        entries = refreshed
                        if !refreshed.contains(where: { $0.id == self.selectedEntryID }) {
                            selectedEntryID = nil
                        }
                        directoryCache.insert(
                            refreshed,
                            for: server.connectionIdentity,
                            path: directory
                        )
                    } else {
                        directoryCache.removeAll()
                    }
                    deletion?.phase = .failed
                    deletion?.message = error.localizedDescription
                }
            }
        }
    }

    func deletePreviewEntry() {
        guard let previewEntry else { return }
        delete(previewEntry)
    }

    func undoDeletion() {
        guard deletion?.phase == .pendingUndo else { return }
        deletionGeneration = UUID()
        deletionTask?.cancel()
        deletionTask = nil
        deletion = nil
        deletionAnnouncement = "Deletion undone. No files were deleted."
    }

    private func waitForDeletionCommit(generation: UUID) async throws {
        try await Task.sleep(for: .seconds(deletionUndoDelay))
        try Task.checkCancellation()
        guard deletionGeneration == generation, deletion?.phase == .pendingUndo else {
            throw CancellationError()
        }
        deletion?.phase = .active
        deletion?.undoDeadline = nil
        if let deletion {
            self.deletion?.message = deletion.entries.count == 1
                ? "Deleting \(deletion.entry.name)…"
                : "Deleting file 1 of \(deletion.entries.count)…"
        }
    }

    func dismissDeletion() {
        guard deletion?.phase == .failed else { return }
        deletion = nil
    }

    func refreshAfterUnknownDeletion() {
        guard
            deletion?.phase == .outcomeUnknown,
            let server = activeServer
        else { return }
        let directory = currentPath
        let generation = deletionGeneration
        deletion?.phase = .active
        deletion?.message = "Refreshing before another deletion…"
        deletionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await service.list(server: server, path: directory)
                guard deletionGeneration == generation else { return }
                entries = refreshed
                selectedFileIDs.formIntersection(
                    Set(refreshed.filter { $0.kind == .file }.map(\.id))
                )
                if !refreshed.contains(where: { $0.id == self.selectedEntryID }) {
                    selectedEntryID = nil
                }
                directoryCache.insert(
                    refreshed,
                    for: server.connectionIdentity,
                    path: directory
                )
                deletion = nil
                deletionTask = nil
            } catch {
                guard deletionGeneration == generation else { return }
                deletion?.phase = .outcomeUnknown
                deletion?.message = RemoteFileError.deleteOutcomeUnknown.localizedDescription
                    + " Refresh again before deleting another file."
                deletionTask = nil
            }
        }
    }

    private func startBatchDeletion(_ targets: [RemoteFileEntry]) {
        guard
            !targets.isEmpty,
            canDeleteSelectedFiles,
            let server = activeServer
        else { return }
        let directory = currentPath
        let firstIndex = targets.compactMap { target in
            entries.firstIndex(where: { $0.id == target.id })
        }.min() ?? 0
        let generation = UUID()
        deletionGeneration = generation
        deletionAnnouncement = nil
        deletion = DeletionPresentation(
            entries: targets,
            phase: .pendingUndo,
            message: "Will delete \(targets.count) \(targets.count == 1 ? "file" : "files")"
        )
        deletion?.undoDeadline = Date().addingTimeInterval(deletionUndoDelay)

        deletionTask = Task { [weak self] in
            guard let self else { return }
            var acknowledged: [RemoteFileEntry] = []
            do {
                try await waitForDeletionCommit(generation: generation)
                for (index, target) in targets.enumerated() {
                    try Task.checkCancellation()
                    guard deletionGeneration == generation else { return }
                    deletion?.currentIndex = index
                    deletion?.completedCount = acknowledged.count
                    deletion?.message = "Deleting file \(index + 1) of \(targets.count)…"
                    try await service.delete(server: server, entry: target)
                    try Task.checkCancellation()
                    acknowledged.append(target)
                    deletion?.completedCount = acknowledged.count
                }

                let refreshedEntries: [RemoteFileEntry]
                let isAuthoritativeRefresh: Bool
                do {
                    refreshedEntries = try await service.list(
                        server: server,
                        path: directory
                    )
                    isAuthoritativeRefresh = true
                } catch {
                    let acknowledgedIDs = Set(acknowledged.map(\.id))
                    refreshedEntries = entries.filter {
                        !acknowledgedIDs.contains($0.id)
                    }
                    isAuthoritativeRefresh = false
                }
                try Task.checkCancellation()
                guard deletionGeneration == generation else { return }
                applyAcknowledgedBatchDeletion(
                    targets: targets,
                    refreshedEntries: refreshedEntries,
                    firstDeletedIndex: firstIndex,
                    isAuthoritativeRefresh: isAuthoritativeRefresh,
                    server: server,
                    directory: directory
                )
            } catch let deletionError {
                guard deletionGeneration == generation else { return }
                deletionTask = nil
                let acknowledgedIDs = Set(acknowledged.map(\.id))
                let currentTarget = targets[min(acknowledged.count, targets.count - 1)]
                let prefix = acknowledged.isEmpty
                    ? ""
                    : "Deleted \(acknowledged.count) of \(targets.count) files. "

                do {
                    let refreshed = try await service.list(
                        server: server,
                        path: directory
                    )
                    guard deletionGeneration == generation else { return }
                    entries = refreshed
                    selectedFileIDs.subtract(acknowledgedIDs)
                    selectedFileIDs.formIntersection(
                        Set(refreshed.filter { $0.kind == .file }.map(\.id))
                    )
                    directoryCache.insert(
                        refreshed,
                        for: server.connectionIdentity,
                        path: directory
                    )
                    deletion?.completedCount = acknowledged.count
                    deletion?.currentIndex = min(acknowledged.count, targets.count - 1)
                    deletion?.phase = .failed
                    if deletionError as? RemoteFileError == .deleteOutcomeUnknown {
                        let stillPresent = refreshed.contains {
                            $0.id == currentTarget.id
                        }
                        deletion?.message = prefix + deletionError.localizedDescription
                            + (stillPresent
                                ? " The current listing still contains this path."
                                : " The current listing no longer contains this path.")
                    } else {
                        deletion?.message = prefix + deletionError.localizedDescription
                    }
                } catch {
                    guard deletionGeneration == generation else { return }
                    entries.removeAll { acknowledgedIDs.contains($0.id) }
                    selectedFileIDs.subtract(acknowledgedIDs)
                    selectedFileIDs.formIntersection(
                        Set(entries.filter { $0.kind == .file }.map(\.id))
                    )
                    directoryCache.removeAll()
                    deletion?.completedCount = acknowledged.count
                    deletion?.currentIndex = min(acknowledged.count, targets.count - 1)
                    if deletionError as? RemoteFileError == .deleteOutcomeUnknown {
                        deletion?.phase = .outcomeUnknown
                        deletion?.message = prefix
                            + RemoteFileError.deleteOutcomeUnknown.localizedDescription
                            + " Refresh again before deleting another file."
                    } else {
                        deletion?.phase = .failed
                        deletion?.message = prefix + deletionError.localizedDescription
                    }
                }
            }
        }
    }

    func cancelTransfer() {
        guard transfer?.phase == .active else { return }
        transfer?.phase = .cancelling
        transfer?.message = "Stopping transfer…"
        transferTask?.cancel()
    }

    func retryTransfer() {
        guard
            let transfer,
            transfer.phase == .failed || transfer.phase == .cancelled,
            !isTransferRunning
        else { return }
        guard
            activeServer?.connectionIdentity == transfer.connectionIdentity,
            RemotePath.normalized(currentPath) == transfer.remoteDirectory
        else {
            self.transfer = nil
            errorMessage = "Return to the original remote folder and choose Download again."
            return
        }
        self.transfer = nil
        startTransfer(entry: transfer.entry, destination: transfer.destination)
    }

    func dismissTransfer() {
        guard !isTransferRunning else { return }
        transfer = nil
    }

    func revealTransfer() {
        guard let destination = transfer?.destination else { return }
        presenter.revealInFinder(destination)
    }

    @discardableResult
    func cancelAll(
        completion: (@MainActor () -> Void)? = nil
    ) -> Bool {
        if let completion {
            shutdownCompletions.append(completion)
        }
        let pendingMutationTasks = [uploadTask, deletionTask].compactMap { $0 }
        loadTask?.cancel()
        previewTask?.cancel()
        transferTask?.cancel()
        uploadTask?.cancel()
        deletionTask?.cancel()
        loadGeneration = UUID()
        previewGeneration = UUID()
        transferGeneration = UUID()
        uploadGeneration = UUID()
        deletionGeneration = UUID()
        loadTask = nil
        previewTask = nil
        transferTask = nil
        uploadTask = nil
        deletionTask = nil
        pendingPath = nil
        isLoading = false
        isRefreshing = false
        directoryCache.removeAll()
        isFolderOpen = false
        cleanupPreview()
        transfer = nil
        upload = nil
        deletion = nil
        deletionAnnouncement = nil
        resetFileSelection()

        if deferredShutdownTask != nil {
            return true
        }
        if !pendingMutationTasks.isEmpty {
            deferredShutdownTask = Task { [weak self, service] in
                for task in pendingMutationTasks {
                    await task.value
                }
                service.shutdown()
                self?.finishDeferredShutdown()
            }
            return true
        } else {
            service.shutdown()
            finishDeferredShutdown()
            return false
        }
    }

    private func load(
        path: String,
        server: RemoteServer,
        previousPath: String?,
        isRefresh: Bool = false,
        popsHistory: Bool = false,
        selectionAfterLoad: String? = nil,
        resolvesFile: Bool = false
    ) {
        let path = RemotePath.normalized(path)
        if isLoading, pendingPath == path {
            return
        }
        if isRefreshing, currentPath == path {
            return
        }

        if !isRefresh, path != currentPath {
            clearFinishedTransfersForNavigation()
        }

        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        errorMessage = nil
        let cachedEntries = isRefresh || resolvesFile
            ? nil
            : directoryCache.entries(
                for: server.connectionIdentity,
                path: path
            )
        let committedFromCache = cachedEntries != nil

        if let cachedEntries {
            commitLoadedFolder(
                path: path,
                entries: cachedEntries,
                previousPath: previousPath,
                isRefresh: false,
                popsHistory: popsHistory,
                selectionAfterLoad: selectionAfterLoad
            )
            pendingPath = nil
            isLoading = false
            isRefreshing = true
            retryLoadRequest = (
                path,
                server,
                nil,
                true,
                false,
                nil,
                false
            )
            screen = .browser
        } else {
            retryLoadRequest = (
                path,
                server,
                previousPath,
                isRefresh,
                popsHistory,
                selectionAfterLoad,
                resolvesFile
            )
            isLoading = !isRefresh
            isRefreshing = isRefresh
            pendingPath = !isRefresh ? path : nil
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: RemotePathLoadResult
                if resolvesFile {
                    result = try await service.loadPath(server: server, path: path)
                } else {
                    result = .directory(try await service.list(server: server, path: path))
                }
                try Task.checkCancellation()
                guard loadGeneration == generation else { return }
                switch result {
                case .directory(let loadedEntries):
                    directoryCache.insert(
                        loadedEntries,
                        for: server.connectionIdentity,
                        path: path
                    )
                    commitLoadedFolder(
                        path: path,
                        entries: loadedEntries,
                        previousPath: committedFromCache ? nil : previousPath,
                        isRefresh: committedFromCache || isRefresh,
                        popsHistory: committedFromCache ? false : popsHistory,
                        selectionAfterLoad: committedFromCache ? nil : selectionAfterLoad
                    )
                    screen = .browser
                case .file(let entry):
                    commitLoadedFile(entry)
                    screen = .browser
                }
                pendingPath = nil
                isLoading = false
                isRefreshing = false
                retryLoadRequest = nil
                if resolvesFile {
                    let recentPath: String
                    switch result {
                    case .directory:
                        recentPath = path
                    case .file(let entry):
                        recentPath = RemotePath.parent(of: entry.path)
                    }
                    if let location = serverCatalog.recordSuccessfulOpen(
                        server,
                        path: recentPath
                    ) {
                        activeLocationID = pendingRootLocationID ?? location.id
                    }
                    recentLocations = serverCatalog.recentLocations(from: tunnels)
                    pendingRootLocationID = nil
                    failedLocationID = nil
                    successfulOpenSequence &+= 1
                } else {
                    serverCatalog.recordSuccessfulOpen(server)
                }
                refreshServers(preferredConnection: server.connectionIdentity)
                if case .file(let entry) = result, entry.isPreviewable {
                    preview(entry)
                }
            } catch is CancellationError {
                if loadGeneration == generation {
                    pendingPath = nil
                    isLoading = false
                    isRefreshing = false
                }
            } catch {
                if loadGeneration == generation {
                    pendingPath = nil
                    isLoading = false
                    isRefreshing = false
                    errorMessage = error.localizedDescription
                    if resolvesFile {
                        failedLocationID = pendingRootLocationID
                        pendingRootLocationID = nil
                    }
                }
            }
        }
    }

    private func commitLoadedFolder(
        path: String,
        entries loadedEntries: [RemoteFileEntry],
        previousPath: String?,
        isRefresh: Bool,
        popsHistory: Bool,
        selectionAfterLoad: String?
    ) {
        if let previousPath {
            navigationHistory.append(previousPath)
        } else if popsHistory, !navigationHistory.isEmpty {
            navigationHistory.removeLast()
        }
        currentPath = path
        isFolderOpen = true
        remotePath = path
        entries = loadedEntries
        if !isRefresh { resetFileSelection() }
        if
            let selectionAfterLoad,
            loadedEntries.contains(where: { $0.id == selectionAfterLoad })
        {
            selectedEntryID = selectionAfterLoad
        } else if
            !isRefresh
                || !loadedEntries.contains(where: { $0.id == selectedEntryID })
        {
            selectedEntryID = nil
        }
    }

    private func commitLoadedFile(_ entry: RemoteFileEntry) {
        currentPath = RemotePath.parent(of: entry.path)
        isFolderOpen = false
        remotePath = entry.path
        entries = [entry]
        selectedEntryID = entry.id
        resetFileSelection()
    }

    private func decodeImage(at url: URL) async throws -> NSImage {
        let decoder = imageDecoder
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try decoder(url)
            try Task.checkCancellation()
            return DecodedRemoteImage(value: image)
        }
        return try await withTaskCancellationHandler {
            let decoded = try await worker.value.value
            return NSImage(
                cgImage: decoded,
                size: NSSize(width: decoded.width, height: decoded.height)
            )
        } onCancel: {
            worker.cancel()
        }
    }

    private func startTransfer(entry: RemoteFileEntry, destination: URL) {
        guard !isTransferRunning, let server = activeServer else {
            errorMessage = "Reopen the remote folder before downloading."
            return
        }
        let generation = UUID()
        transferGeneration = generation
        transfer = TransferPresentation(
            entry: entry,
            destination: destination,
            connectionIdentity: server.connectionIdentity,
            remoteDirectory: RemotePath.normalized(currentPath),
            completedBytes: 0,
            totalBytes: entry.isDirectory ? nil : entry.size,
            phase: .active
        )

        transferTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.download(
                    server: server,
                    entry: entry,
                    to: destination
                ) { [weak self] completedBytes in
                    Task { @MainActor in
                        guard
                            let self,
                            self.transferGeneration == generation,
                            self.transfer?.phase == .active
                        else { return }
                        self.transfer?.completedBytes = completedBytes
                    }
                }
                try Task.checkCancellation()
                guard transferGeneration == generation else { return }
                transfer?.completedBytes = transfer?.totalBytes ?? transfer?.completedBytes ?? 0
                transfer?.phase = .completed
                transfer?.message = nil
                transferTask = nil
            } catch is CancellationError {
                guard transferGeneration == generation else { return }
                transfer?.phase = .cancelled
                transfer?.message =
                    "Canceled. Temporary data was removed; existing files were unchanged."
                transferTask = nil
            } catch {
                guard transferGeneration == generation else { return }
                transfer?.phase = .failed
                transfer?.message =
                    "\(error.localizedDescription) Temporary data was removed; "
                    + "existing files were unchanged."
                transferTask = nil
            }
        }
    }

    private func startUpload(localFile: URL, replaceExisting: Bool) {
        guard
            let server = activeServer,
            screen == .browser,
            isFolderOpen,
            !isTransferRunning
        else {
            errorMessage = "Reopen the remote folder before uploading."
            return
        }
        let directory = currentPath
        let generation = UUID()
        uploadGeneration = generation
        let totalBytes = Int64(
            max(
                0,
                (try? localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
        )
        upload = UploadPresentation(
            localFile: localFile,
            replaceExisting: replaceExisting,
            connectionIdentity: server.connectionIdentity,
            remoteDirectory: RemotePath.normalized(directory),
            phase: .active,
            operationPhase: .staging,
            completedBytes: 0,
            totalBytes: totalBytes,
            isStagingComplete: false,
            message: "Staging safely…"
        )

        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.uploadWithProgress(
                    server: server,
                    localFile: localFile,
                    remoteDirectory: directory,
                    replaceExisting: replaceExisting
                ) { [weak self] update in
                    Task { @MainActor in
                        guard
                            let self,
                            self.uploadGeneration == generation,
                            self.upload?.phase == .active
                        else { return }
                        let previous = self.upload?.completedBytes ?? 0
                        self.upload?.operationPhase = update.phase
                        self.upload?.completedBytes = max(
                            previous,
                            min(update.completedBytes, update.totalBytes)
                        )
                        self.upload?.totalBytes = update.totalBytes
                        self.upload?.isStagingComplete = update.isStagingComplete
                        self.upload?.message = update.phase.presentationText
                    }
                }
                guard uploadGeneration == generation else { return }
                upload?.phase = .completed
                upload?.message = "Uploaded to \(directory)."
                uploadTask = nil
                refresh()
            } catch is CancellationError {
                guard uploadGeneration == generation else { return }
                upload?.phase = .cancelled
                upload?.message =
                    "Canceled before publication. No remote file was published, "
                    + "and RelayBar has no known staging file left."
                uploadTask = nil
            } catch {
                guard uploadGeneration == generation else { return }
                upload?.phase = .failed
                upload?.message = error.localizedDescription
                uploadTask = nil
                if error as? RemoteFileError == .uploadConflict {
                    refresh()
                }
            }
        }
    }

    private func applyAcknowledgedDeletion(
        entry: RemoteFileEntry,
        refreshedEntries: [RemoteFileEntry],
        browserIndex: Int,
        imageIndex: Int,
        previewIndex: Int,
        deletedFromPreview: Bool,
        isAuthoritativeRefresh: Bool,
        server: RemoteServer,
        directory: String
    ) {
        let refreshedEntries = isAuthoritativeRefresh
            ? refreshedEntries
            : refreshedEntries.filter { $0.id != entry.id }
        entries = refreshedEntries
        directoryCache.insert(
            refreshedEntries,
            for: server.connectionIdentity,
            path: directory
        )
        deletion = nil
        deletionTask = nil

        if deletedFromPreview {
            let candidates = entry.isPreviewableImage
                ? refreshedEntries.filter(\.isPreviewableImage)
                : refreshedEntries.filter(\.isPreviewable)
            let preferredIndex = entry.isPreviewableImage ? imageIndex : previewIndex
            if !candidates.isEmpty {
                let target = candidates[min(preferredIndex, candidates.count - 1)]
                selectedEntryID = target.id
                deletionAnnouncement = "Deleted \(entry.name). Showing \(target.name)."
                preview(target)
            } else {
                deletionAnnouncement = entry.isPreviewableImage
                    ? "Deleted \(entry.name). No images remain."
                    : "Deleted \(entry.name). No previewable files remain."
                retirePreviewForLocationChange()
                screen = .browser
                selectedEntryID = refreshedEntries.isEmpty
                    ? nil
                    : refreshedEntries[min(browserIndex, refreshedEntries.count - 1)].id
            }
        } else {
            deletionAnnouncement = "Deleted \(entry.name)."
            selectedEntryID = refreshedEntries.isEmpty
                ? nil
                : refreshedEntries[min(browserIndex, refreshedEntries.count - 1)].id
        }
    }

    private func applyAcknowledgedBatchDeletion(
        targets: [RemoteFileEntry],
        refreshedEntries: [RemoteFileEntry],
        firstDeletedIndex: Int,
        isAuthoritativeRefresh: Bool,
        server: RemoteServer,
        directory: String
    ) {
        let targetIDs = Set(targets.map(\.id))
        let currentEntries = isAuthoritativeRefresh
            ? refreshedEntries
            : refreshedEntries.filter { !targetIDs.contains($0.id) }
        entries = currentEntries
        directoryCache.insert(
            currentEntries,
            for: server.connectionIdentity,
            path: directory
        )
        deletion = nil
        deletionTask = nil
        deletionAnnouncement = targets.count == 1
            ? "Deleted \(targets[0].name)."
            : "Deleted \(targets.count) files."
        selectedEntryID = currentEntries.isEmpty
            ? nil
            : currentEntries[min(firstDeletedIndex, currentEntries.count - 1)].id
        resetFileSelection()
    }

    private func cleanupPreview() {
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
        }
        previewURL = nil
        previewVideoURL = nil
        previewProgress = nil
    }

    private func retirePreviewForLocationChange() {
        previewTask?.cancel()
        previewGeneration = UUID()
        previewTask = nil
        cleanupPreview()
        previewEntry = nil
        previewImage = nil
        previewMarkdown = nil
        previewJSON = nil
        previewVideoURL = nil
        previewProgress = nil
        isLoadingPreview = false
    }

    private func clearFinishedTransfersForNavigation() {
        guard !isTransferRunning else { return }
        upload = nil
        transfer = nil
        deletion = nil
        resetFileSelection()
    }

    private func resetFileSelection() {
        selectedFileIDs = []
        isSelectingFiles = false
    }

    private func finishDeferredShutdown() {
        deferredShutdownTask = nil
        let completions = shutdownCompletions
        shutdownCompletions = []
        for completion in completions {
            completion()
        }
    }

    private func refreshServers(
        preferredConnection: RemoteServer.ConnectionIdentity?
    ) {
        let updatedServers = serverCatalog.servers(from: tunnels)
        servers = updatedServers
        recentLocations = serverCatalog.recentLocations(from: tunnels)
        if
            let preferredConnection,
            let preferred = updatedServers.first(where: {
                $0.connectionIdentity == preferredConnection
            })
        {
            selectedServerID = preferred.id
        } else {
            selectedServerID = updatedServers.first?.id
        }
    }

    var isDeletionInProgress: Bool {
        deletion?.phase == .pendingUndo || deletion?.phase == .active
    }

    private var isTransferRunning: Bool {
        transfer?.phase == .active || transfer?.phase == .cancelling
            || upload?.phase == .active || upload?.phase == .cancelling
            || isDeletionInProgress
    }
}
