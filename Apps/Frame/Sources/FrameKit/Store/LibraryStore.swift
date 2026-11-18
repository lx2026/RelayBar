import BridgeProtocol
import AssetGrouping
import AppKit
import Combine
import Composition
import Foundation
import SwiftData
import UniformTypeIdentifiers

public enum FrameViewMode: String, Codable, Sendable { case inspect, contactSheet }

public struct FrameNotice: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let message: String
  public let actionTitle: String?
  public init(message: String, actionTitle: String? = nil) {
    self.message = message
    self.actionTitle = actionTitle
  }
}

public struct RecentFolder: Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let parentPath: String
  public let available: Bool
}

@MainActor
public final class LibraryStore: ObservableObject {
  public typealias Scanner = FrameLibraryFeatures.Scanner
  @Published public private(set) var photos: [PhotoItem] = [] { didSet { scopeChanged() } }
  @Published public private(set) var rootFolder: FolderNode?
  @Published public private(set) var localFolders: LocalFolderIndex?
  @Published public private(set) var documentRevision = 0
  @Published public var showsDocumentInfo = false
  /// A Markdown file's details are its "On this page" outline, shown until Hide Details.
  @Published public var showsDocumentOutline = true
  @Published public private(set) var showsMediaInfo = true
  public var showsInfo: Bool {
    guard let photo = selectedPhoto else { return showsMediaInfo }
    if photo.format == .markdown { return showsDocumentOutline }
    return photo.format.isDocument ? showsDocumentInfo : showsMediaInfo
  }
  public func toggleInfo() {
    if selectedPhoto?.format == .markdown { showsDocumentOutline.toggle() }
    else if selectedPhoto?.format.isDocument == true { showsDocumentInfo.toggle() }
    else { enqueuePreference { $0.showsMediaInfo.toggle() } }
  }
  /// Rendered or Source for Markdown and HTML. Starts as Rendered and holds while the app runs.
  public var showsDocumentSource: Bool { documentRenderer.showsSource }
  public func setShowsDocumentSource(_ value: Bool) {
    guard !isClosing else { return }
    documentRenderer.setShowsSource(value)
  }
  /// Each listed folder's baseline by path, and the modification time each file had when it was last shown in
  /// Files mode, keyed like favourites.
  @Published public private(set) var folderBaselines: [String: Date] = [:]
  @Published public private(set) var openedTimes: [String: Date] = [:]
  /// True while the catalog can keep baselines and opened times.
  private var tracksChanges = false
  /// True for a file modified after its folder's baseline and after it was last shown in Files mode.
  public func isChanged(_ photo: PhotoItem) -> Bool {
    guard photo.archiveID == nil, photo.rootID == activeRootID else { return false }
    return ChangeTracking.isChanged(modified: ChangeTracking.modificationDate(of: photo),
      baseline: folderBaselines[photo.folderRelativePath], opened: openedTimes[photo.favoriteID])
  }
  /// The view that displays a file in Files mode reports it here; only that counts as opening it.
  public func noteDisplayed(_ photo: PhotoItem) {
    guard !isClosing, viewMode == .inspect, photo.id == selectionID, !selectionMissing, !rootUnavailable,
          isChanged(photo), let modified = ChangeTracking.modificationDate(of: photo),
          let feature = previews.library.favorites, feature.isActive else { return }
    do { try feature.markOpened(rootID: photo.rootID, relativePath: photo.relativePath, at: modified) } catch { return }
    openedTimes[photo.favoriteID] = modified
  }
  /// "N selected" when the file actions will act on more, or other, than one file.
  public var selectionCountLabel: String? {
    let count = actionPhotos.count
    return isSelecting || count != 1 ? "\(count) selected" : nil
  }
  private var localTreeSubscription: AnyCancellable?
  private var missingPreview: PhotoItem?
  @Published public private(set) var rootURL: URL?
  @Published public private(set) var remoteSource: BridgeSource? { didSet { scopeChanged() } }
  @Published public private(set) var remotePath = ""
  @Published public private(set) var remoteError: String?
  @Published public var showsOpenChooser = false
  @Published public private(set) var showsRemoteFolders: Bool
  @Published public private(set) var localIncludesSubfolders: Bool { didSet { scopeChanged() } }
  @Published public private(set) var remoteIncludesSubfolders = false { didSet { scopeChanged() } }
  @Published public private(set) var remoteFolders: RemoteFolderIndex?
  @Published public private(set) var isScanningSubfolders = false
  @Published public private(set) var remoteScannedFolders = 0
  @Published public private(set) var remoteScanIssue: String?
  public var includesSubfolders: Bool { isRemote ? remoteIncludesSubfolders : localIncludesSubfolders }
  @Published public private(set) var remoteLocations: [BridgeLocation] = []
  @Published public private(set) var remoteCatalogError: String?
  @Published public private(set) var isLoadingRemoteLocations = false
  public var isRemote: Bool { remoteSource != nil }
  public var availableFilters: [PhotoFilter] { PhotoFilter.allCases }
  @Published public private(set) var originalPreview: PhotoItem?
  @Published public private(set) var isLoadingOriginal = false
  private var originalTask: Task<Void, Never>?
  @Published public private(set) var rootName = ""
  @Published public private(set) var activeRootID: UUID?
  @Published public private(set) var rootUnavailable = false
  @Published public private(set) var selectionMissing = false
  @Published public private(set) var recentFolders: [RecentFolder] = []
  @Published public private(set) var selectedFolderPath = "" { didSet { scopeChanged() } }
  @Published public private(set) var filter: PhotoFilter = .all { didSet { scopeChanged() } }
  @Published public private(set) var fileTypeFilter: FileTypeFilter = .all { didSet { scopeChanged() } }
  /// Companion files are folded into the file they describe unless this is on.
  @Published public private(set) var showsSidecarFiles = false { didSet { scopeChanged() } }
  @Published public private(set) var folderIsSelected = false
  @Published public private(set) var selectionID: PhotoItem.ID?
  @Published public private(set) var batchSelection = MediaSelection()
  @Published public private(set) var isSelecting = false
  @Published public var showsFolderOutline: Bool?
  @Published public private(set) var thumbnailWidth: Double
  @Published public private(set) var favorites: Set<PhotoItem.ID> = [] { didSet { scopeChanged() } }
  /// Prompt Search's words. Empty while no search is active.
  @Published public private(set) var searchQuery = ""
  /// The assets the latest result for the query matched; nil until that first result and while no query is active.
  @Published private var searchMatches: Set<PhotoItem.ID>? { didSet { visibleCache = nil } }
  /// How many assets the list shows while a search result narrows it.
  public var searchMatchCount: Int? { searchMatches == nil ? nil : visiblePhotos.count }
  /// True while Prompt Search is present for the world being shown.
  public var isSearchAvailable: Bool { searchFeature?.isActive == true }
  private var searchFeature: FramePromptSearchFeature? {
    previews.runtime.service(FrameServices.PromptSearch.self, realm: isRemote ? "remote" : nil)
  }
  /// Increases each time the search field is asked to take the keyboard focus.
  @Published public private(set) var searchFocusRequests = 0
  /// The pending search, owned by `presentation`. Readable so tests can wait for one.
  private(set) var searchTask: Task<Void, Never>?
  private var searchGeneration = UUID()
  @Published public private(set) var metadata = ImageMetadata()
  @Published public private(set) var isScanning = false
  @Published public private(set) var isExporting = false
  @Published public private(set) var viewMode: FrameViewMode = .contactSheet
  @Published public private(set) var isFocusMode = false
  @Published public private(set) var notice: FrameNotice?
  @Published public var errorMessage: String?
  public var undoCount: Int { previews.files.undoCount }
  @Published public private(set) var isFileOperation = false
  @Published public private(set) var operationProgress = 0
  @Published public private(set) var operationTotal = 0
  @Published public private(set) var operationTitle = ""
  @Published public var fileActionFailures: [FileActionFailure] = []
  @Published public var fileActionSummary = ""
  public let previews: FrameComposition
  public var playback: PlaybackController { previews.playback }
  public var documentRenderer: DocumentRenderer { previews.documentRenderer }
  private var previewObservation: AnyCancellable?
  public var gridScrollPositions: [String: Double] = [:]
  public var gridScopeKey: String { "\(activeRootID?.uuidString ?? "")|\(selectedFolderPath)|\(filter.rawValue)|\(fileTypeFilter.rawValue)|\(includesSubfolders)|\(showsSidecarFiles)" }

  private var started = false
  private var featureObservations: Set<AnyCancellable> = []
  private var metadataGeneration: String?
  private var visibleCache: [PhotoItem]?
  private var metadataTask: Task<Void, Never>?
  private var noticeTask: Task<Void, Never>?
  private var scanTask: Task<ScanResult, Error>?
  private var remoteTask: Task<ScanResult, Error>?
  private var remoteScanTask: Task<Void, Never>?
  private var remoteScanGeneration = UUID()
  private var remoteTreeSubscription: AnyCancellable?
  private var scanGeneration = UUID()
  private let presentation = EffectScope()
  private var isClosing = false
  private var playbackReady: AnyCancellable?
  private var hasRemoteAuthority: Bool { showsRemoteFolders && previews.remoteLibrary.isAvailable }
  private var preferencesObservation: AnyCancellable?
  private var preferenceTask: Task<Void, Never>?

  public init(defaults: UserDefaults = .standard, scanner: @escaping Scanner = { url, id in
    try FileScanner.scan(rootURL: url, rootID: id)
  }, previews: FrameComposition? = nil) {
    let previews = previews ?? FrameComposition()
    self.previews = previews
    previews.preferences.configure(defaults: defaults)
    let preferences = previews.preferences.value
    showsMediaInfo = preferences.showsMediaInfo
    previews.library.configure(defaults: defaults, scanner: scanner)
    showsRemoteFolders = preferences.showsRemoteFolders
    localIncludesSubfolders = preferences.localIncludesSubfolders
    thumbnailWidth = preferences.thumbnailWidth
    previews.remoteDidWithdraw = { [weak self] in self?.remoteWasWithdrawn($0) }
    previews.errorHandler = { [weak self] in self?.errorMessage = $0.localizedDescription }
    previewObservation = previews.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    // Each port publishes when its feature is replaced by a new instance; the view state it feeds reloads then.
    let runtime = previews.runtime
    runtime.port(FrameServices.Catalog.self).$value.sink { [weak self] in if $0 != nil { self?.catalogBecameAvailable() } }
      .store(in: &featureObservations)
    runtime.port(FrameServices.Favorites.self).$value.sink { [weak self] in if $0 != nil { self?.favoritesBecameAvailable() } }
      .store(in: &featureObservations)
    runtime.port(FrameServices.Scanning.self).$value.sink { [weak self] in if $0 != nil { self?.scanningBecameAvailable() } }
      .store(in: &featureObservations)
    for port in [runtime.port(FrameServices.Metadata.self), runtime.port(FrameServices.Metadata.self, realm: "remote"),
                 runtime.port(FrameServices.HelperMetadata.self)] {
      port.$generation.dropFirst().sink { [weak self] _ in self?.metadataReaderChanged() }.store(in: &featureObservations)
    }
    runtime.port(FrameServices.PromptSearch.self).$generation.dropFirst()
      .sink { [weak self] _ in self?.searchFeatureChanged(remote: false) }.store(in: &featureObservations)
    runtime.port(FrameServices.PromptSearch.self, realm: "remote").$generation.dropFirst()
      .sink { [weak self] _ in self?.searchFeatureChanged(remote: true) }.store(in: &featureObservations)
    preferencesObservation = previews.preferences.values.sink { [weak self] in self?.applyPreferences($0) }
    playbackReady = playback.$player.dropFirst().sink { [weak self] player in
      guard player != nil, let self, let photo = self.selectedPhoto, photo.remote != nil else { return }
      self.loadMetadata(for: photo)
    }
  }

  public func setThumbnailWidth(_ value: Double) async {
    let width = ContactSheetMetrics.normalizedWidth(value)
    guard !isClosing else { return }
    do { try await previews.updatePreferences { $0.thumbnailWidth = width } }
    catch { errorMessage = error.localizedDescription }
  }

  private func enqueuePreference(_ change: @escaping @MainActor (inout FramePreferenceValues) -> Void) {
    guard !isClosing else { return }
    let previous = preferenceTask
    preferenceTask = try? presentation.task { [weak self] in
      await previous?.value
      guard let self else { return }
      do { try await previews.updatePreferences(change) }
      catch { errorMessage = error.localizedDescription }
    }
  }

  func settlePreferences() async { await preferenceTask?.value }

  private func rememberLayout() {
    guard let id = activeRootID else { return }
    let mode = viewMode
    enqueuePreference { $0.layouts[id.uuidString] = mode }
  }

  private func applyPreferences(_ value: FramePreferenceValues) {
    guard !isClosing else { return }
    showsMediaInfo = value.showsMediaInfo
    thumbnailWidth = value.thumbnailWidth
    if localIncludesSubfolders != value.localIncludesSubfolders {
      localIncludesSubfolders = value.localIncludesSubfolders
      if !isRemote {
        if value.localIncludesSubfolders { refresh() }
        ensureValidSelection(reload: false)
      }
    }
    guard showsRemoteFolders != value.showsRemoteFolders else { return }
    showsRemoteFolders = value.showsRemoteFolders
    if !showsRemoteFolders {
      remoteLocations = []; remoteCatalogError = nil
      if isRemote {
        resetRemoteSession(); scanGeneration = UUID(); isScanning = false
        clearSelection(); photos = []; rootFolder = nil; rootURL = nil; activeRootID = nil
        rootName = ""; selectedFolderPath = ""; filter = .all; viewMode = .contactSheet; isFocusMode = false
      }
    }
  }

  deinit {
    metadataTask?.cancel()
    scanTask?.cancel()
    remoteTask?.cancel()
    remoteScanTask?.cancel()
    noticeTask?.cancel()
    searchTask?.cancel()
  }

  public func shutdown() async {
    isClosing = true
    presentation.invalidate()
    scanGeneration = UUID(); remoteScanGeneration = UUID()
    let local = localFolders
    local?.stop(); remoteFolders?.stop()
    localTreeSubscription = nil; remoteTreeSubscription = nil
    scanTask?.cancel(); remoteTask?.cancel(); remoteScanTask?.cancel()
    metadataTask?.cancel(); originalTask?.cancel(); noticeTask?.cancel()
    previews.files.cancel()
    await settlePreferences()
    await previews.stop()
    _ = try? await scanTask?.value; _ = try? await remoteTask?.value
    await remoteScanTask?.value; await metadataTask?.value; await originalTask?.value
    await noticeTask?.value
    await presentation.dispose()
    await local?.shutdown()
    previews.library.closeLocalRoot()
  }

  public var visiblePhotos: [PhotoItem] {
    if let visibleCache { return visibleCache }
    let scope = searchScope
    let result = searchMatches.map { matches in scope.filter { matches.contains($0.id) } } ?? scope
    visibleCache = result
    return result
  }
  /// The current folder after its filters, before Prompt Search narrows it.
  private var searchScope: [PhotoItem] {
    PhotoQuery.visiblePhotos(in: photos, folderRelativePath: selectedFolderPath,
                             filter: filter, favorites: favorites, includeSubfolders: includesSubfolders,
                             fileType: fileTypeFilter, includeCompanions: showsSidecarFiles)
  }
  public var selectedPhoto: PhotoItem? {
    guard let selectionID else { return nil }
    return photos.first { $0.id == selectionID }
      ?? (missingPreview?.id == selectionID ? missingPreview : nil)
  }
  public var hasAvailableSelection: Bool {
    !isClosing && selectedPhoto != nil && !selectionMissing && !rootUnavailable && !isScanning && !isFileOperation && !showsOpenChooser
  }
  public var canExport: Bool {
    previews.files.canExport && hasAvailableSelection && visibleSelectedPhoto != nil && (!isRemote || (hasRemoteAuthority && previews.files.canRemoteExport)) && selectedPhoto?.companionOwnerID == nil && !isExporting &&
      (viewMode == .inspect || (batchSelection.ids.count == 1 && batchSelection.ids.contains(selectionID ?? "")))
  }
  public var canFavorite: Bool { hasAvailableSelection && !favoritePhotos.isEmpty && previews.library.canFavorite }
  public var canOpenLocalFolder: Bool { !isClosing && !isFileOperation && previews.library.canUseCatalog && previews.library.canScan }
  public var canInspect: Bool {
    hasAvailableSelection
  }
  public var canRefresh: Bool { !isClosing && (rootURL != nil || isRemote) && !isScanning && !isFileOperation && (isRemote || previews.library.canScan) }
  public var canUndoTrash: Bool { !isClosing && previews.files.canTrash && !isRemote && undoCount > 0 && !isFileOperation }
  public var undoTitle: String { previews.files.undoTitle }
  public var selectedGridPhotos: [PhotoItem] { visiblePhotos.filter { batchSelection.ids.contains($0.id) } }
  /// What delete, archive and restore act on. Only assets the list shows, in every layout.
  public var actionPhotos: [PhotoItem] { isSelecting || viewMode == .contactSheet ? selectedGridPhotos : visibleSelectedPhoto.map { [$0] } ?? [] }
  /// The selected asset while the list shows it, so nothing a search or filter hides can be acted on.
  private var visibleSelectedPhoto: PhotoItem? {
    selectedPhoto.flatMap { photo in visiblePhotos.contains { $0.id == photo.id } ? photo : nil }
  }
  private var canMutateSelection: Bool {
    !isClosing && (!isRemote || hasRemoteAuthority) && !showsOpenChooser && !actionPhotos.isEmpty && actionPhotos.allSatisfy { $0.companionOwnerID == nil && AssetCompanionNames.isPrimary($0.name) } && !rootUnavailable && !isScanning && !isFileOperation && !isExporting
      && (viewMode == .contactSheet || !selectionMissing)
  }
  public var canDelete: Bool { canMutateSelection && (isRemote ? previews.files.canRemoteDelete : previews.files.canTrash) }
  private func uniqueMembers(_ items: [PhotoItem]) -> [AssetFile] {
    Array(Dictionary(items.flatMap(\.exportMembers).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first }).values)
  }
  public var selectedByteCount: Int64 { uniqueMembers(selectedGridPhotos).reduce(0) { $0 + $1.size } }
  public var canArchive: Bool { canMutateSelection && (isRemote ? previews.files.canRemoteArchive : previews.files.canArchive) }
  public var deleteTitle: String { isRemote ? "Delete" : "Move to Trash" }
  public var groupedActionHelp: String? {
    if actionPhotos.contains(where: { $0.companionOwnerID != nil }) {
      return "Companion files are managed with their image or video. Select the owner to manage the whole group."
    }
    if actionPhotos.contains(where: { !AssetCompanionNames.isPrimary($0.name) }) {
      return "Archive and delete are available for images, videos, Markdown and HTML."
    }
    return nil
  }
  public var deleteHelp: String { groupedActionHelp ?? (isRemote ? "Delete selected items and companion files permanently (⌫)" : "Move selected items and companion files to Trash (⌫)") }
  private var favoritePhotos: [PhotoItem] { viewMode == .inspect || isSelecting ? visibleSelectedPhoto.map { [$0] } ?? [] : actionPhotos }
  public var allActionPhotosFavorite: Bool { !favoritePhotos.isEmpty && favoritePhotos.allSatisfy(isFavorite) }
  public var selectedMemberCount: Int { uniqueMembers(actionPhotos).count }
  public var exportHelp: String {
    selectedPhoto?.companionOwnerID == nil ? "Export (⇧⌘E)" : "Select the image or video to export it with its companion files."
  }
  public func companionDescription(_ photo: PhotoItem) -> String? {
    guard let id = photo.companionOwnerID else { return nil }
    let owner = photos.first { $0.id == id } ?? files(in: photo.folderRelativePath).first { $0.id == id }
    return owner.map { "Companion of \($0.name)" } ?? "Companion file"
  }
  public var canOpenSelectedInDefaultApp: Bool {
    hasAvailableSelection && (!isRemote || (hasRemoteAuthority && previews.media.canResolveOriginal))
  }
  /// Opens the selected file, downloading a remote one first, in the app macOS assigns to it.
  public func openSelectedInDefaultApp() {
    guard canOpenSelectedInDefaultApp, let photo = selectedPhoto else { return }
    _ = try? presentation.task { [self] in
      do {
        let file = photo.remote == nil ? photo : try await previews.media.resolveOriginal(photo)
        guard !isClosing else { return }
        NSWorkspace.shared.open(file.url)
      } catch { if !isClosing { errorMessage = error.localizedDescription } }
    }
  }
  /// The files the tree lists in a folder: companions are folded into their owner unless Show Sidecar Files is on.
  public func treeFiles(in path: String) -> [PhotoItem] {
    let all = files(in: path)
    return showsSidecarFiles ? all : all.filter { $0.companionOwnerID == nil }
  }
  /// An asset's companion files, in its own order, made from its own companion list so they do not depend on
  /// the folder still being cached. A listed item is used when there is one.
  public func companionItems(of photo: PhotoItem) -> [PhotoItem] {
    guard !photo.companions.isEmpty else { return [] }
    let listed = Dictionary(files(in: photo.folderRelativePath).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    return photo.companions.map { companion in
      if let item = listed[companion.relativePath] { return item }
      var item = FileScanner.item(companion, rootID: photo.rootID,
                                  format: .browsing(pathExtension: (companion.relativePath as NSString).pathExtension))
      item.companionOwnerID = photo.id
      if let remote = photo.remote, let entry = remote.companions.first(where: { $0.path == companion.relativePath }) {
        item.remote = RemoteAssetReference(source: remote.source, listingID: remote.listingID, entry: entry)
      }
      return item
    }
  }
  /// Shows a companion file in Files mode. Companions are listed again so it stays in reach of Previous and Next.
  public func openCompanion(_ item: PhotoItem) {
    guard !isClosing, !isFileOperation else { return }
    showFile(item)
  }
  public func setShowsSidecarFiles(_ value: Bool) {
    guard !isClosing, !isFileOperation, value != showsSidecarFiles else { return }
    let owner = value ? nil : selectedPhoto?.companionOwnerID.flatMap { id in photos.first { $0.id == id } }
    showsSidecarFiles = value
    // A sidecar on show gives way to the file it describes rather than to the folder's first file.
    if let owner, visiblePhotos.contains(where: { $0.id == owner.id }) {
      batchSelection.preview(owner.id, keepingSelection: isSelecting)
      preview(owner)
    }
    ensureValidSelection(reload: false)
  }
  /// The folder a selection in the tree shows: selecting a file opens it in Files mode.
  public func showFile(_ photo: PhotoItem) {
    guard !isClosing, !isFileOperation else { return }
    if viewMode != .inspect {
      viewMode = .inspect
      rememberLayout()
      isFocusMode = false
    }
    selectFile(photo)
  }
  /// Subfolders of the folder on show, as Icons mode lists them before its files.
  public var subfolders: [FolderTile] {
    guard filter != .archive else { return [] }
    if let remoteFolders {
      return (remoteFolders.nodes[selectedFolderPath]?.children ?? [])
        .map { FolderTile(path: $0, name: ($0 as NSString).lastPathComponent) }
    }
    return (localFolders?.results[selectedFolderPath]?.rootFolder.children ?? rootFolderChildren(selectedFolderPath))
      .map { FolderTile(path: $0.relativePath, name: $0.name) }
  }
  private func rootFolderChildren(_ path: String) -> [FolderNode] {
    func find(_ node: FolderNode) -> FolderNode? {
      node.relativePath == path ? node : node.children.lazy.compactMap(find).first
    }
    return rootFolder.flatMap(find)?.children ?? []
  }
  /// The folder tiles Icons mode shows first: only while Subfolders is off and nothing narrows the files.
  public var gridFolders: [FolderTile] {
    guard !includesSubfolders, !hasFileFilters, searchQuery.isEmpty else { return [] }
    return subfolders
  }
  /// How many files of each kind the folder holds after its favourite filter, before the kind filter.
  public var kindCounts: [FileTypeFilter: Int] {
    if let kindCountsCache { return kindCountsCache }
    let scope = PhotoQuery.visiblePhotos(in: photos, folderRelativePath: selectedFolderPath, filter: filter,
      favorites: favorites, includeSubfolders: includesSubfolders, includeCompanions: showsSidecarFiles)
    var counts: [FileTypeFilter: Int] = [:]
    for photo in scope {
      for kind in FileTypeFilter.allCases where kind.includes(photo.format) { counts[kind, default: 0] += 1 }
    }
    kindCountsCache = counts
    return counts
  }
  /// The counts above and the folder's file count, kept until the folder, its filters or its files change.
  private var kindCountsCache: [FileTypeFilter: Int]?
  private var folderFileCountCache: Int?
  /// The name of the folder on show.
  public var shownFolderName: String {
    if filter == .archive { return "Archive" }
    if isRemote {
      let root = remoteFolders?.rootPath ?? remotePath
      return selectedFolderPath == root && root == "/" ? rootName : (selectedFolderPath as NSString).lastPathComponent
    }
    return selectedFolderPath.isEmpty ? rootName : (selectedFolderPath as NSString).lastPathComponent
  }
  public var folderChoices: [FolderNode] {
    func flatten(_ node: FolderNode) -> [FolderNode] { node.children.flatMap { [$0] + flatten($0) } }
    guard let rootFolder else { return [] }
    let choices = flatten(rootFolder)
    return choices.contains { $0.photoCount < rootFolder.photoCount } ? choices : []
  }

  public func start(modelContext: ModelContext) async {
    guard !isClosing else { return }
    guard !started else { return }
    do { try await previews.bindLibrary(modelContext); started = true }
    catch { errorMessage = error.localizedDescription; return }
    reloadRecents()
    if activeRootID == nil, let first = recentFolders.first { await openRecent(first.id) }
  }

  public func presentOpenPanel() { presentFolderPanel(relocating: nil) }
  public func presentOpenChooser() { guard !isFileOperation else { return }; showsOpenChooser = true }
  public func setShowsRemoteFolders(_ value: Bool) async {
    guard !isClosing, !isFileOperation else { return }
    do { try await previews.updatePreferences { $0.showsRemoteFolders = value } }
    catch { errorMessage = error.localizedDescription }
  }
  public func setIncludesSubfolders(_ value: Bool) async {
    guard !isClosing, !isFileOperation, filter != .archive else { return }
    if isRemote {
      remoteIncludesSubfolders = value
      cancelRemoteScan()
      if value { startRemoteScan() }
      else {
        photos = photos.filter { $0.folderRelativePath == remotePath }
        ensureValidSelection(reload: false)
      }
    } else {
      do { try await previews.updatePreferences { $0.localIncludesSubfolders = value } }
      catch { errorMessage = error.localizedDescription }
    }
  }
  /// Only reads RelayBar's authorized catalog; never connects to saved hosts or persists a second history.
  public func refreshRemoteLocations() async {
    guard !isClosing, showsRemoteFolders, !isLoadingRemoteLocations else { return }
    isLoadingRemoteLocations = true
    defer { isLoadingRemoteLocations = false }
    do {
      let feature = try await previews.connectLibrary()
      let catalog = try await feature.catalog()
      guard !isClosing, !Task.isCancelled, showsRemoteFolders else { return }
      remoteLocations = catalog.locations ?? []
      remoteCatalogError = nil
    } catch {
      guard !isClosing, !Task.isCancelled, showsRemoteFolders else { return }
      remoteLocations = []
      remoteCatalogError = error.localizedDescription
    }
  }
  public func openRelayBar() {
    guard showsRemoteFolders else { return }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FrameBridgeEnvironment.relayBundle) else {
      errorMessage = "Install RelayBar to browse remote folders."; return
    }
    do { try FrameBridgeEnvironment.verifyApplication(url, bundleID: FrameBridgeEnvironment.relayBundle) }
    catch { errorMessage = error.localizedDescription; return }
    showsOpenChooser = false
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
  }

  public func handleHandoff(_ url: URL) async {
    guard !isFileOperation, url.scheme == "frame-viewer", url.host == "handoff",
          url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
          url.pathComponents.count == 2, let nonce = UUID(uuidString: url.lastPathComponent) else { return }
    guard showsRemoteFolders else { errorMessage = "Remote folders are hidden. Enable them in Frame Settings."; return }
    do {
      let handoff = try await previews.client.handoff(nonce)
      await openRemote(handoff.source, path: handoff.path, focus: handoff.focus)
    } catch { errorMessage = error.localizedDescription }
  }

  public func openRemote(_ source: BridgeSource, path: String, focus: [String] = [], preserveSelection: Bool = false,
                         browseFolder: Bool = false) async {
    guard !isClosing, !isFileOperation, showsRemoteFolders, FrameBridgeEnvironment.validSource(source), FrameBridgeEnvironment.validPath(path) else { return }
    let feature: FrameRemoteLibraryFeature
    do { feature = try await previews.connectLibrary() }
    catch { remoteError = error.localizedDescription; return }
    guard !isClosing, showsRemoteFolders else { return }
    showsOpenChooser = false
    let path = "/" + path.split(separator: "/").joined(separator: "/")
    let previousID = preserveSelection ? selectionID : nil
    let previousBatch = preserveSelection ? batchSelection.ids : []
    scanTask?.cancel(); remoteTask?.cancel(); cancelRemoteScan()
    let token = UUID(); scanGeneration = token
    await localFolders?.shutdown()
    await previews.retireSelection()
    guard scanGeneration == token, !isClosing, feature.isActive else { return }
    previews.library.closeLocalRoot()
    localFolders = nil; localTreeSubscription = nil
    clearSelection()
    remoteSource = source; remotePath = path; remoteError = nil
    if remoteFolders?.source != source || !(remoteFolders.map { feature.owns($0) && (RemoteFolderIndex.contains(path, in: $0.rootPath) || RemoteFolderIndex.contains($0.rootPath, in: path)) } ?? false) {
      remoteFolders?.stop()
      let tree: RemoteFolderIndex
      do { tree = try feature.makeIndex(source: source, path: path) }
      catch { remoteError = error.localizedDescription; return }
      remoteFolders = tree
      remoteTreeSubscription = tree.objectWillChange.sink { [weak self] _ in
        self?.objectWillChange.send()
        // Folders the tree lists as they are expanded get their baselines once the change has landed.
        DispatchQueue.main.async { self?.recordRemoteBaselines() }
      }
      remoteIncludesSubfolders = false
    }
    guard let tree = remoteFolders else { return }
    tree.reveal(path)
    tree.setExpanded(path, true)
    if preserveSelection { tree.invalidate(path) }
    rootURL = nil; rootName = source.name; rootUnavailable = false
    let rootID = RelayRemoteClient.rootID(source.id)
    activeRootID = rootID
    photos = []; rootFolder = nil; selectedFolderPath = path
    if !preserveSelection && !browseFolder { filter = .all; fileTypeFilter = .all }
    if browseFolder && filter == .archive { filter = .all }
    await settlePreferences()
    guard scanGeneration == token, !isClosing, feature.isActive else { return }
    // Choosing a folder keeps the current mode; opening a location uses the one remembered for it.
    viewMode = browseFolder ? viewMode : previews.preferences.value.layout(for: rootID)
    folderIsSelected = focus.isEmpty
    isFocusMode = false; isScanning = true
    loadFavorites(rootID: rootID)
    loadChangeState(rootID: rootID)
    let task = Task { try await tree.load(path) }
    remoteTask = task
    do {
      let result = try await task.value
      guard scanGeneration == token, !Task.isCancelled else { return }
      photos = result.files; rootFolder = result.rootFolder; isScanning = false
      recordListing(folder: path, files: result.files)
      let focused = photos.filter { focus.contains($0.name) || $0.companions.contains { focus.contains($0.url.lastPathComponent) } }
      selectionID = focused.first?.id ?? previousID
      batchSelection.update(ids: focused.isEmpty ? previousBatch : Set(focused.map(\.id)), currentID: selectionID)
      ensureValidSelection(reload: true)
      if remoteIncludesSubfolders { startRemoteScan() }
      // Frame consumes RelayBar's history; navigation here never changes it.
    } catch {
      guard scanGeneration == token else { return }
      isScanning = false; remoteError = error.localizedDescription
    }
  }

  public func remoteParent() {
    guard let source = remoteSource, remotePath != "/" else { return }
    let parent = (remotePath as NSString).deletingLastPathComponent
    _ = try? presentation.task { [self] in await openRemote(source, path: parent.isEmpty ? "/" : parent, browseFolder: true) }
  }
  public func toggleRemoteFolder(_ path: String) {
    guard !isFileOperation, let tree = remoteFolders else { return }
    setRemoteFolderExpanded(path, !tree.expanded.contains(path))
  }
  public func setRemoteFolderExpanded(_ path: String, _ expand: Bool) {
    guard !isClosing, !isFileOperation, let tree = remoteFolders else { return }
    tree.setExpanded(path, expand)
    if expand { _ = try? presentation.task { _ = try? await tree.load(path) } }
  }
  public func stopRemoteScan() {
    cancelRemoteScan(); remoteScanIssue = "Stopped. Showing folders loaded so far."
  }
  private func cancelRemoteScan() {
    remoteScanTask?.cancel(); remoteScanTask = nil; remoteScanGeneration = UUID()
    isScanningSubfolders = false; remoteScanIssue = nil; remoteScannedFolders = 0
  }
  private func startRemoteScan() {
    guard !isClosing, let tree = remoteFolders, remoteIncludesSubfolders, !isScanning,
          let feature = previews.remoteLibrary.feature, feature.isActive else { return }
    cancelRemoteScan()
    let token = UUID(); remoteScanGeneration = token
    let path = remotePath
    isScanningSubfolders = true
    remoteScanTask = Task { [weak self] in
      do {
        try await feature.scan(tree, path: path) { [weak self] snapshot in
          guard let self, self.remoteScanGeneration == token else { return }
          let wasEmpty = self.photos.isEmpty
          self.photos = snapshot.files
          self.remoteScannedFolders = snapshot.folders
          self.remoteScanIssue = snapshot.issues.isEmpty ? nil : snapshot.issues.joined(separator: "\n")
          self.isScanningSubfolders = !snapshot.finished
          if wasEmpty && self.selectionID == nil { self.ensureValidSelection(reload: false) }
        }
      } catch {
        guard let self, self.remoteScanGeneration == token else { return }
        self.isScanningSubfolders = false
        if !(error is CancellationError) { self.remoteScanIssue = error.localizedDescription }
      }
    }
  }
  private func remoteWasWithdrawn(_ message: String) {
    remoteLocations = []; remoteCatalogError = message
    guard isRemote else { return }
    scanGeneration = UUID(); remoteTask?.cancel(); cancelRemoteScan(); remoteFolders?.cancelAll()
    metadataTask?.cancel(); originalTask?.cancel(); originalPreview = nil; isLoadingOriginal = false
    isScanning = false; remoteError = message
    // Keep the last listing and rendered document; new reads/actions require fresh capabilities.
  }

  private func resetRemoteSession() {
    cancelRemoteScan(); remoteTask?.cancel(); remoteFolders?.stop()
    remoteTreeSubscription = nil; remoteFolders = nil
    remoteSource = nil; remotePath = ""; remoteError = nil; remoteIncludesSubfolders = false
  }
  public func locateRoot() { presentFolderPanel(relocating: activeRootID) }

  private func presentFolderPanel(relocating id: UUID?) {
    guard canOpenLocalFolder else { return }
    let panel = NSOpenPanel()
    panel.title = id == nil ? "Choose a folder" : "Locate \(rootName)"
    panel.message = id == nil ? ""
      : "Choose this folder’s current location to keep its favorites."
    panel.prompt = id == nil ? "Choose Folder" : "Use This Folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.allowedContentTypes = [.folder]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    _ = try? presentation.task { [self] in await openRoot(url, replacingRootID: id) }
  }

  public func openRoot(_ url: URL, replacingRootID: UUID? = nil) async {
    guard !isClosing, !isFileOperation, previews.library.canScan, let catalog = previews.library.catalog else { return }
    do {
      let location = try catalog.open(url, replacing: replacingRootID)
      reloadRecents()
      await activate(url: location.url, record: location.root)
    } catch { errorMessage = "Could not open the folder: \(error.localizedDescription)" }
  }

  public func openRecent(_ id: UUID) async {
    guard !isClosing, !isFileOperation, previews.library.canScan, let catalog = previews.library.catalog,
          let record = try? catalog.record(id) else { return }
    showsOpenChooser = false
    do {
      let location = try catalog.recent(id)
      await activate(url: location.url, record: location.root)
      reloadRecents()
    } catch { makeUnavailable(record: record) }
  }

  public func removeRecent(_ id: UUID) {
    guard !isClosing, let catalog = previews.library.catalog else { return }
    do { try catalog.hide(id); reloadRecents() }
    catch { errorMessage = error.localizedDescription }
  }

  public func selectFolder(_ relativePath: String) {
    guard !isClosing, !isFileOperation else { return }
    if let source = remoteSource {
      _ = try? presentation.task { [self] in await openRemote(source, path: relativePath, browseFolder: true) }
      return
    }
    if filter == .archive { filter = .all }
    showsOpenChooser = false
    selectedFolderPath = relativePath
    folderIsSelected = true
    isFocusMode = false
    batchSelection.replace(with: nil)
    selectionID = nil
    previews.clearPlayback()
    ensureValidSelection(reload: true)
    if let localFolders {
      _ = try? presentation.task { [weak self] in
        guard let result = try? await localFolders.load(relativePath) else { return }
        guard let self, !isClosing, self.localFolders === localFolders,
              selectedFolderPath == relativePath else { return }
        installDirectory(relativePath, result)
        if selectionID == nil { ensureValidSelection(reload: false) }
      }
    }
  }
  public func files(in path: String) -> [PhotoItem] {
    if let remoteFolders { return remoteFolders.files(at: path) }
    return localFolders?.results[path]?.files ?? photos.filter { $0.folderRelativePath == path && $0.archiveID == nil }
  }
  public func selectFile(_ photo: PhotoItem) {
    guard !isClosing, !isFileOperation else { return }
    folderIsSelected = false
    // An explicit choice reveals the file: a search that hides it, or has not yet shown it, ends first.
    if !searchQuery.isEmpty, searchMatches?.contains(photo.id) != true {
      removeSearch()
    }
    if filter == .archive && photo.archiveID == nil { filter = .all }
    if !fileTypeFilter.includes(photo.format) { fileTypeFilter = .all }
    if photo.companionOwnerID != nil, !showsSidecarFiles { showsSidecarFiles = true }
    if (filter == .favorites && !isFavorite(photo)) || (filter == .notFavorited && isFavorite(photo)) { filter = .all }
    selectedFolderPath = photo.folderRelativePath
    if isRemote { remotePath = photo.folderRelativePath }
    if !photos.contains(where: { $0.id == photo.id }) {
      photos.append(photo)
    }
    batchSelection.replace(with: photo.id)
    preview(photo)
  }
  public func openDocumentLink(_ relative: String) {
    let generation = scanGeneration
    _ = try? presentation.task { [self] in
      do {
        let path = try DocumentResources.normalized(relative)
        let item: PhotoItem?
        if let tree = remoteFolders {
          let full = (tree.rootPath == "/" ? "" : tree.rootPath) + "/" + path
          let parent = (full as NSString).deletingLastPathComponent
          tree.reveal(parent); tree.setExpanded(parent, true)
          item = try await tree.load(parent).files.first { $0.relativePath == full }
        } else if let tree = localFolders {
          let parent = (path as NSString).deletingLastPathComponent
          tree.reveal(parent)
          item = try await tree.load(parent).files.first { $0.relativePath == path }
        } else { item = nil }
        guard !isClosing, scanGeneration == generation else { return }
        if let item { selectFile(item) }
      } catch { if !isClosing, scanGeneration == generation { errorMessage = error.localizedDescription } }
    }
  }
  public var documentLocation: DocumentLocation? {
    if let photo = selectedPhoto, photo.archiveID != nil {
      if let remote = photo.remote { return .remote(remote.source, (remote.entry.path as NSString).deletingLastPathComponent) }
      return .local(photo.url.deletingLastPathComponent())
    }
    if let source = remoteSource { return .remote(source, remoteFolders?.rootPath ?? remotePath) }
    return rootURL.map { .local($0) }
  }
  public func documentPath(_ photo: PhotoItem) -> String {
    if photo.archiveID != nil { return photo.name }
    guard isRemote else { return photo.relativePath }
    let root = remoteFolders?.rootPath ?? remotePath
    return root == "/" ? String(photo.relativePath.dropFirst()) : String(photo.relativePath.dropFirst(root.count + 1))
  }
  public func setViewMode(_ mode: FrameViewMode) {
    guard !isFileOperation, mode != viewMode else { return }
    viewMode = mode; rememberLayout(); isFocusMode = false
    if let photo = selectedPhoto { prepareSelection(photo) }
    if mode == .contactSheet, !isRemote, includesSubfolders { rescanLocal() }
  }
  private func installDirectory(_ path: String, _ result: ScanResult) {
    guard !isFileOperation else { return }
    let old = selectedPhoto
    photos.removeAll { $0.folderRelativePath == path && $0.archiveID == nil }
    photos += result.files
    photos.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    if let old, old.folderRelativePath == path {
      if let updated = result.files.first(where: { $0.id == old.id }) {
        selectionMissing = false; missingPreview = nil
        if old.contentID != updated.contentID { prepareSelection(updated) }
      } else { missingPreview = old; selectionMissing = true }
    }
    recordListing(folder: path, files: result.files)
  }
  public func setFilter(_ newFilter: PhotoFilter) {
    guard !isClosing, !isFileOperation, availableFilters.contains(newFilter) else { return }
    if newFilter == .archive, !(isRemote ? previews.files.canRemoteArchive : previews.files.canArchive) { return }
    let wasCollection = filter == .archive
    filter = newFilter
    if isRemote {
      if newFilter == .archive { _ = try? presentation.task { [self] in await loadRemoteArchive() }; return }
      if wasCollection, let source = remoteSource {
        let path = remotePath
        _ = try? presentation.task { [self] in
          await openRemote(source, path: path)
          guard !isClosing, remoteSource == source, remotePath == path else { return }
          filter = newFilter; ensureValidSelection(reload: true)
        }
        return
      }
    }
    if newFilter == .archive { selectedFolderPath = "" }
    if newFilter == .archive, !isRemote, let rootURL, let activeRootID, let feature = previews.files.archive {
      _ = try? presentation.task { [self] in
        do {
          let archived = try await feature.load(root: rootURL, rootID: activeRootID)
          guard !isClosing, self.activeRootID == activeRootID, filter == .archive else { return }
          photos.removeAll { $0.archiveID != nil }; photos += archived.photos
          ensureValidSelection(reload: true)
        } catch { if !isClosing, !(error is CancellationError) { errorMessage = error.localizedDescription } }
      }
    }
    batchSelection.replace(with: nil)
    selectionID = nil
    previews.clearPlayback()
    ensureValidSelection(reload: true)
  }
  public var hasFileFilters: Bool {
    fileTypeFilter != .all || (filter != .all && filter != .archive)
  }
  public var folderFileCount: Int {
    if let folderFileCountCache { return folderFileCountCache }
    let count = PhotoQuery.visiblePhotos(in: photos, folderRelativePath: selectedFolderPath,
      filter: filter == .archive ? .archive : .all, favorites: [], includeSubfolders: includesSubfolders,
      includeCompanions: showsSidecarFiles).count
    folderFileCountCache = count
    return count
  }
  public var isReadingFolder: Bool {
    isScanning || (remoteFolders?.loading.contains(selectedFolderPath) ?? localFolders?.loading.contains(selectedFolderPath) ?? false)
  }
  public var folderReadError: String? {
    guard filter != .archive else { return nil }
    return remoteError ?? remoteFolders?.nodes[selectedFolderPath]?.error ?? localFolders?.errors[selectedFolderPath]
  }
  public func retrySelectedFolder() {
    guard !isClosing, !isFileOperation else { return }
    if isRemote { refresh(); return }
    guard let tree = localFolders else { return }
    let path = selectedFolderPath
    _ = try? presentation.task { [weak self] in
      guard let result = try? await tree.load(path, force: true), let self,
            !isClosing, localFolders === tree, selectedFolderPath == path else { return }
      installDirectory(path, result); ensureValidSelection(reload: true)
    }
  }
  public var fileFilterLabel: String {
    fileTypeFilter.rawValue + (filter == .favorites || filter == .notFavorited ? " · \(filter.rawValue)" : "")
  }
  public var folderContainsSubfolders: Bool {
    if let remoteFolders { return !(remoteFolders.nodes[selectedFolderPath]?.children.isEmpty ?? true) }
    return !(localFolders?.results[selectedFolderPath]?.rootFolder.children.isEmpty ?? true)
  }
  public func setFileTypeFilter(_ value: FileTypeFilter) {
    guard !isClosing, !isFileOperation, value != fileTypeFilter else { return }
    fileTypeFilter = value
    batchSelection.replace(with: nil)
    ensureValidSelection(reload: false)
  }
  public func clearFileFilters() {
    guard !isClosing, !isFileOperation else { return }
    if !searchQuery.isEmpty {
      removeSearch()
    }
    fileTypeFilter = .all
    if filter != .archive { filter = .all }
    batchSelection.replace(with: nil)
    ensureValidSelection(reload: false)
  }
  /// Sets Prompt Search's words. A new query searches after a short pause and keeps the previous result
  /// on screen until then; an empty query ends the search at once.
  public func setSearchQuery(_ query: String) {
    guard !isClosing, !isFileOperation, query != searchQuery, isSearchAvailable else { return }
    guard !query.isEmpty else {
      removeSearch()
      return
    }
    searchQuery = query
    scheduleSearch()
  }
  /// Asks the search field to take the keyboard focus.
  public func focusSearch() {
    guard isSearchAvailable else { return }
    searchFocusRequests += 1
  }
  public func select(_ photo: PhotoItem) {
    guard !isFileOperation, visiblePhotos.contains(where: { $0.id == photo.id }) else { return }
    folderIsSelected = false
    batchSelection.preview(photo.id, keepingSelection: isSelecting)
    preview(photo)
  }

  public func updateGridSelection(_ ids: Set<String>, currentID: String?) {
    guard !isFileOperation else { return }
    folderIsSelected = false
    let available = Set(visiblePhotos.map(\.id))
    batchSelection.update(ids: ids.intersection(available), currentID: currentID.flatMap { available.contains($0) ? $0 : nil }, keepingPreview: isSelecting)
    if let photo = visiblePhotos.first(where: { $0.id == batchSelection.currentID }) { preview(photo) }
    else { clearSelection() }
  }

  public func toggleSelectMode() {
    guard !isFileOperation else { return }
    isSelecting.toggle()
    if isSelecting { batchSelection.update(ids: [], currentID: selectionID, keepingPreview: true) }
    else { batchSelection.replace(with: selectionID) }
  }

  public func toggleCurrentSelection() {
    guard isSelecting, hasAvailableSelection, let selectionID else { return }
    var ids = batchSelection.ids
    if !ids.insert(selectionID).inserted { ids.remove(selectionID) }
    batchSelection.update(ids: ids, currentID: selectionID, keepingPreview: true)
  }

  private func preview(_ photo: PhotoItem) {
    let changed = selectionID != photo.id
    selectionID = photo.id
    selectionMissing = photo.remote == nil && !FileManager.default.isReadableFile(atPath: photo.url.path)
    if selectionMissing {
      previews.clearPlayback()
      metadataTask?.cancel()
      metadata = ImageMetadata()
      return
    }
    if changed || metadata.identity.isEmpty || (photo.format.isVideo && playback.player == nil && !playback.isPreparing) { prepareSelection(photo) }
  }
  public func navigate(by offset: Int) {
    let items = visiblePhotos
    guard !items.isEmpty, !rootUnavailable, !isScanning, !isFileOperation else { return }
    folderIsSelected = false
    let index = selectionID.flatMap { id in items.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : 0)
    let next = items[(index + offset % items.count + items.count) % items.count]
    batchSelection.preview(next.id, keepingSelection: isSelecting)
    preview(next)
  }

  public func toggleFavorite() {
    guard canFavorite, let feature = previews.library.favorites else { return }
    let targets = favoritePhotos
    let previousOrder = visiblePhotos.map(\.id)
    let previousID = selectionID
    let value = !allActionPhotosFavorite
    do {
      try feature.set(targets, favorite: value)
      if value { favorites.formUnion(targets.map(\.favoriteID)) }
      else { favorites.subtract(targets.map(\.favoriteID)) }
      if targets.count == 1, let previousID, let index = previousOrder.firstIndex(of: previousID) {
        let remaining = Dictionary(uniqueKeysWithValues: visiblePhotos.map { ($0.id, $0) })
        let nextID = (Array(previousOrder.dropFirst(index + 1)) + Array(previousOrder.prefix(index)))
          .first { remaining[$0] != nil } ?? (remaining[previousID] == nil ? nil : previousID)
        if let nextID, let next = remaining[nextID] {
          if isSelecting {
            batchSelection.update(ids: batchSelection.ids.intersection(remaining.keys), currentID: nextID, keepingPreview: true)
          } else { batchSelection.replace(with: nextID) }
          preview(next)
        } else { clearSelection() }
      } else { ensureValidSelection(reload: false) }
    } catch { errorMessage = "Could not save favorite: \(error.localizedDescription)" }
  }
  public func isFavorite(_ photo: PhotoItem) -> Bool { favorites.contains(photo.favoriteID) }

  public func toggleContactSheet() {
    guard !isFileOperation, !visiblePhotos.isEmpty else { return }
    if viewMode == .inspect {
      previews.clearPlayback()
      viewMode = .contactSheet
      rememberLayout()
      isFocusMode = false
      if let photo = selectedPhoto, photo.remote != nil && photo.format.isVideo { previews.preparePlayback(photo) }
    } else {
      guard selectedPhoto != nil else { return }
      viewMode = .inspect
      rememberLayout()
      if let selectedPhoto { prepareSelection(selectedPhoto) }
    }
  }
  public func inspect(_ photo: PhotoItem) {
    guard !isFileOperation else { return }
    viewMode = .inspect
    rememberLayout()
    preview(photo)
    if photo.format.isVideo && playback.player == nil { prepareSelection(photo) }
  }
  public func openViewer() {
    guard canInspect else { return }
    if viewMode == .contactSheet {
      viewMode = .inspect
      rememberLayout()
      if let selectedPhoto { prepareSelection(selectedPhoto) }
    }
  }
  public func escape() {
    if viewMode == .contactSheet && isScanningSubfolders { stopRemoteScan(); return }
    if NSApp?.keyWindow?.styleMask.contains(.fullScreen) == true {
      NSApp.keyWindow?.toggleFullScreen(nil)
      isFocusMode = false
    } else if isFocusMode { isFocusMode = false }
    else if viewMode == .inspect { toggleContactSheet() }
  }
  /// The window entered or left full screen, by any means; leaving it ends the full-screen viewer.
  public func fullScreenDidChange(_ isFullScreen: Bool) {
    if !isFullScreen, isFocusMode { isFocusMode = false }
  }
  /// Brings the search field into view, leaving the full-screen viewer and showing the folders column, then
  /// gives it the focus once it exists.
  public func revealSearch() {
    guard isSearchAvailable else { return }
    let hidden = isFocusMode || showsFolderOutline == false
    if isFocusMode {
      if let window = NSApp?.keyWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
      isFocusMode = false
    }
    if showsFolderOutline == false { showsFolderOutline = true }
    guard hidden else { focusSearch(); return }
    // A field made after a request does not answer it, so the request waits for the column to be drawn.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusSearch() }
  }
  public func toggleFullScreen() {
    guard canInspect, let window = NSApp?.keyWindow else { return }
    if window.styleMask.contains(.fullScreen) {
      isFocusMode = false
    } else {
      if viewMode == .contactSheet, let selectedPhoto { inspect(selectedPhoto) }
      beginFocusMode(watching: window)
    }
    window.toggleFullScreen(nil)
  }
  /// The full-screen viewer lasts only while its window is full screen: it ends when the window leaves full
  /// screen however that happens, closes, or has not entered full screen within `focusEntryTimeout`.
  func beginFocusMode(watching window: NSWindow) {
    endFocusWatch()
    isFocusMode = true
    let token = UUID()
    focusToken = token
    let center = NotificationCenter.default
    let end: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated { self?.endFocusMode(token) }
    }
    focusObservers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: nil, using: end))
    focusObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil, using: end))
    focusObservers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { if self?.focusToken == token { self?.focusEntered = true } }
    })
    focusEntered = window.styleMask.contains(.fullScreen)
    DispatchQueue.main.asyncAfter(deadline: .now() + focusEntryTimeout) { [weak self, weak window] in
      guard let self, focusToken == token, !focusEntered, window?.styleMask.contains(.fullScreen) != true else { return }
      endFocusMode(token)
    }
  }
  private func endFocusMode(_ token: UUID) {
    guard focusToken == token else { return }
    isFocusMode = false
    endFocusWatch()
  }
  private func endFocusWatch() {
    focusObservers.forEach(NotificationCenter.default.removeObserver)
    focusObservers = []
    focusToken = nil
  }
  private var focusObservers: [NSObjectProtocol] = []
  private var focusToken: UUID?
  private var focusEntered = false
  /// How long the window may take to enter full screen before the viewer gives up; tests shorten it.
  var focusEntryTimeout: TimeInterval = 3
  public func togglePlayback() {
    guard hasAvailableSelection, viewMode == .inspect, selectedPhoto?.format.isVideo == true else { return }
    if playback.player == nil, let photo = selectedPhoto, photo.remote != nil, !playback.isPreparing {
      previews.preparePlayback(photo, downloadOriginal: true); return
    }
    playback.toggle()
  }

  public func loadOriginal() {
    guard let photo = selectedPhoto, photo.remote != nil, !isLoadingOriginal else { return }
    originalTask?.cancel(); isLoadingOriginal = true
    originalTask = try? presentation.task { [weak self] in
      guard let self, !isClosing else { return }
      do {
        let local = try await previews.media.resolveOriginal(photo)
        guard !Task.isCancelled, selectionID == photo.id else { return }
        originalPreview = local; isLoadingOriginal = false
      } catch {
        guard !Task.isCancelled else { return }
        isLoadingOriginal = false; errorMessage = error.localizedDescription
      }
    }
  }

  private func loadRemoteArchive() async {
    guard !isClosing, hasRemoteAuthority, let source = remoteSource, filter == .archive,
          let feature = previews.files.remoteArchive, feature.isActive else { return }
    let chosen = filter, path = remotePath
    cancelRemoteScan(); remoteTask?.cancel()
    let token = UUID(); scanGeneration = token
    clearSelection(); photos = []; selectedFolderPath = ""; isScanning = true; remoteError = nil
    do {
      let value = try await feature.load(source: source, root: path)
      guard token == scanGeneration, filter == chosen else { return }
      photos = value; isScanning = false; ensureValidSelection(reload: true)
    } catch {
      guard token == scanGeneration else { return }
      isScanning = false; remoteError = error.localizedDescription
    }
  }

  private func remoteAction(_ action: String) async {
    guard isRemote, action == "delete" ? canDelete : canArchive else { return }
    let targets = actionPhotos, path = remotePath
    let source = remoteSource, tree = remoteFolders
    let oldOrder = visiblePhotos.map(\.id), oldCurrent = selectionID
    cancelRemoteScan()
    // Only Archive can be undone (by Restore); a remote Delete is permanent.
    if action == "archive" { holdOpened(targets) }
    beginFileOperation(action == "delete" ? "Deleting" : action == "restore" ? "Restoring" : "Archiving", total: targets.count, stopsPlayback: true)
    let result: RemoteMutationResult
    do {
      if action == "delete" {
        guard let feature = previews.files.remoteDelete else { isFileOperation = false; return }
        result = try await feature.delete(targets, root: path)
      } else {
        guard let feature = previews.files.remoteArchive else { isFileOperation = false; return }
        result = try await feature.apply(targets, root: path, restoring: action == "restore") { [weak self] in self?.setOperationProgress($0) }
      }
    } catch { isFileOperation = false; if !isClosing { errorMessage = error.localizedDescription }; return }
    isFileOperation = false
    let removedTargets = targets.filter { result.removed.contains($0.id) }
    if action == "delete" { forgetOpened(removedTargets) }
    guard !isClosing, remoteSource == source, remoteFolders === tree else { return }
    operationProgress = result.processed
    let removedPaths = Set(removedTargets.flatMap { $0.fileMembers.map(\.relativePath) })
    photos.removeAll { result.removed.contains($0.id) || removedPaths.contains($0.relativePath) }
    tree?.remove(removedTargets)
    reconcileRemoval(oldOrder: oldOrder, oldCurrent: oldCurrent)
    let completed = result.removed.count
    showNotice("\(completed) \(action == "delete" ? "deleted" : action == "restore" ? "restored" : "archived")"
      + (operationProgress < targets.count ? " · \(targets.count - operationProgress) not processed" : ""))
    reportFailures(result.failures, "\(completed) \(action == "delete" ? "deleted" : "processed"); \(result.failures.count) failed.")
  }

  private func reconcileRemoval(oldOrder: [String], oldCurrent: String?) {
    let items = visiblePhotos, available = Set(items.map(\.id))
    batchSelection.reconcile(with: items.map(\.id))
    let nextID = MediaSelection.nextPreview(in: oldOrder, current: oldCurrent, removing: Set(oldOrder).subtracting(available))
    guard let next = items.first(where: { $0.id == nextID }) else { clearSelection(); return }
    batchSelection.preview(next.id, keepingSelection: isSelecting)
    preview(next)
  }

  public func refresh() {
    guard !isClosing else { return }
    let requestedGeneration = scanGeneration
    documentRevision += 1
    if selectedPhoto?.format.isDocument == true, canRefresh, filter != .archive {
      let path = selectedFolderPath, rootID = activeRootID
      let remote = remoteFolders, local = localFolders
      _ = try? presentation.task { [self] in
        guard !isClosing, scanGeneration == requestedGeneration else { return }
        do {
          let result: ScanResult
          if let tree = remote { tree.invalidate(path); result = try await tree.load(path) }
          else if let tree = local { result = try await tree.load(path, force: true) }
          else { return }
          guard !isClosing, scanGeneration == requestedGeneration, activeRootID == rootID, selectedFolderPath == path else { return }
          installDirectory(path, result)
        } catch {
          if !isClosing, scanGeneration == requestedGeneration { errorMessage = error.localizedDescription }
        }
      }
      return
    }
    if let source = remoteSource, canRefresh {
      let path = remotePath, archived = filter == .archive
      _ = try? presentation.task { [self] in
        guard !isClosing, scanGeneration == requestedGeneration else { return }
        if archived { await loadRemoteArchive() }
        else { await openRemote(source, path: path, preserveSelection: true) }
      }
      return
    }
    rescanLocal()
  }

  /// Scans the whole local folder again, as Icons mode needs with Subfolders on whatever kind of file is selected.
  private func rescanLocal() {
    let requestedGeneration = scanGeneration
    guard !isClosing, !isRemote, canRefresh, let rootURL, let activeRootID else { return }
    let selection = selectionID
    _ = try? presentation.task { [self] in
      guard !isClosing, scanGeneration == requestedGeneration else { return }
      await previews.media.invalidate()
      guard !isClosing, scanGeneration == requestedGeneration else { return }
      await scan(rootURL: rootURL, rootID: activeRootID, preserveSelection: selection)
      reloadRecents()
    }
  }

  /// Revalidate access when returning from Finder; directory changes are handled by FSEvents.
  public func validateSourceAvailability() {
    guard !isScanning, !isFileOperation, let rootURL else { return }
    if !FileManager.default.isReadableFile(atPath: rootURL.path) {
      if let activeRootID, let record = record(activeRootID) { makeUnavailable(record: record, url: rootURL) }
    } else if let photo = selectedPhoto, !FileManager.default.isReadableFile(atPath: photo.url.path) {
      selectionMissing = true
      previews.clearPlayback()
      metadataTask?.cancel()
      metadata = ImageMetadata()
    }
  }

  public func deleteSelected() {
    guard canDelete else {
      if !isClosing, !isFileOperation, let reason = groupedActionHelp { showNotice(reason) }
      return
    }
    _ = try? presentation.task { [self] in await deleteSelection() }
  }

  public func deleteSelection() async {
    if isRemote { await remoteAction("delete"); return }
    guard canDelete, let rootURL, let activeRootID, let feature = previews.files.trash else { return }
    let targets = actionPhotos
    let oldItems = visiblePhotos
    let oldCurrent = selectionID
    holdOpened(targets)
    beginFileOperation("Moving to Trash", total: targets.count, stopsPlayback: true)
    let result: TrashBatchResult
    do { result = try await feature.move(targets, root: rootURL, rootID: activeRootID) { [weak self] in self?.setOperationProgress($0) } }
    catch { isFileOperation = false; if !isClosing { errorMessage = error.localizedDescription }; return }
    guard !isClosing else { isFileOperation = false; return }
    let removed = Set(result.successes.map { $0.photo.id })
    let removedPaths = Set(result.successes.flatMap { $0.photo.fileMembers.map(\.relativePath) })
    photos.removeAll { removed.contains($0.id) || removedPaths.contains($0.relativePath) }
    rootFolder = FolderTreeBuilder.build(rootURL: rootURL, photos: photos)
    isFileOperation = false
    if !result.partialRecoveries.isEmpty {
      await scan(rootURL: rootURL, rootID: activeRootID, preserveSelection: nil)
    }
    reconcileRemoval(oldOrder: oldItems.map(\.id), oldCurrent: oldCurrent)
    let message = "Moved \(result.successes.count) to Trash"
      + (result.unprocessed.isEmpty ? "" : " · \(result.unprocessed.count) not processed")
    showNotice(message, action: result.successes.isEmpty ? nil : "Undo")
    reportFailures(result.failures, "\(result.successes.count) moved; \(result.failures.count) could not be moved.")
  }

  public func cancelFileOperation() { previews.files.cancel() }
  public func archiveSelected() {
    guard canArchive else { return }
    _ = try? presentation.task { [self] in await archiveSelection() }
  }
  public func archiveSelection() async {
    if isRemote { await remoteAction(filter == .archive ? "restore" : "archive"); return }
    guard canArchive, let rootURL, let activeRootID, let feature = previews.files.archive else { return }
    let targets = actionPhotos
    let restoring = filter == .archive
    if !restoring { holdOpened(targets) }
    beginFileOperation(restoring ? "Restoring Archive" : "Archiving", total: targets.count, stopsPlayback: true)
    let result: ArchiveBatchResult
    do { result = try await feature.apply(targets, root: rootURL, restoring: restoring) { [weak self] in self?.setOperationProgress($0) } }
    catch { isFileOperation = false; if !isClosing { errorMessage = error.localizedDescription }; return }
    isFileOperation = false
    guard !isClosing else { return }
    let failures = result.failures
    operationProgress = result.processed
    await scan(rootURL: rootURL, rootID: activeRootID, preserveSelection: nil)
    let completed = operationProgress - failures.count
    showNotice("\(restoring ? "Restored" : "Archived") \(completed)"
      + (operationProgress < targets.count ? " · \(targets.count - operationProgress) not processed" : ""))
    reportFailures(failures, "\(failures.count) could not be \(restoring ? "restored" : "archived").")
  }
  private func setOperationProgress(_ count: Int) { operationProgress = count }
  private func beginFileOperation(_ title: String, total: Int, stopsPlayback: Bool) {
    isFileOperation = true
    operationTitle = title
    operationTotal = total
    operationProgress = 0
    if stopsPlayback { previews.clearPlayback() }
  }
  private func reportFailures(_ failures: [FileActionFailure], _ summary: String) {
    guard !failures.isEmpty else { return }
    fileActionSummary = summary
    fileActionFailures = failures
  }
  public func undoTrash() { _ = try? presentation.task { [self] in await restoreLastTrash() } }
  public func restoreLastTrash() async {
    guard canUndoTrash, let feature = previews.files.trash else { return }
    beginFileOperation("Restoring from Trash", total: previews.files.undoAssetCount, stopsPlayback: false)
    let result: TrashRestoreResult
    do {
      guard let restored = try await feature.restoreLast() else { isFileOperation = false; return }
      result = restored
    } catch { isFileOperation = false; if !isClosing { errorMessage = error.localizedDescription }; return }
    isFileOperation = false
    guard !isClosing else { return }
    let group = result.group
    operationTotal = group.files.count
    if activeRootID == group.rootID, let rootURL {
      await scan(rootURL: rootURL, rootID: group.rootID, preserveSelection: result.restored.first?.id)
      let restoredIDs = Set(result.restored.map(\.id)).intersection(visiblePhotos.map(\.id))
      if !restoredIDs.isEmpty { updateGridSelection(restoredIDs, currentID: result.restored.first?.id) }
    }
    showNotice("Restored \(result.restored.count)")
    reportFailures(result.errors, "\(result.restored.count) restored; \(result.errors.count) could not be restored. No files were replaced.")
  }
  public func performNoticeAction() { if notice?.actionTitle == "Undo" { undoTrash() } }
  public func dismissNotice() { noticeTask?.cancel(); notice = nil }

  public func exportSelected() {
    validateSourceAvailability()
    guard canExport, let photo = selectedPhoto else { return }
    if photo.remote != nil {
      guard let feature = previews.files.remoteExporter, feature.isActive else { return }
      isExporting = true
      _ = try? presentation.task { [self] in
        do {
          let resolved = try await feature.resolve(photo)
          isExporting = false
          guard !isClosing, previews.files.canExport, !Task.isCancelled else { return }
          presentExport(resolved)
        } catch { isExporting = false; if !isClosing { errorMessage = error.localizedDescription } }
      }
      return
    }
    presentExport(photo)
  }

  private func presentExport(_ photo: PhotoItem) {
    guard !isClosing, previews.files.canExport else { return }
    if !photo.companions.isEmpty { exportPaired(photo); return }
    let panel = NSSavePanel()
    panel.title = "Export"
    panel.prompt = "Export"
    panel.nameFieldStringValue = photo.name
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.allowedContentTypes = [UTType(filenameExtension: photo.url.pathExtension) ?? .data]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    // The panel asks before replacing a file at the chosen name, so only one there now was agreed to.
    let replacing = AssetPaths.exists(destination)
    _ = try? presentation.task { [self] in await export(photo, to: destination, replacing: replacing) }
  }

  private func exportPaired(_ photo: PhotoItem) {
    guard !isClosing, !isExporting else { return }
    let panel = NSOpenPanel()
    panel.title = "Export"
    panel.message = "Includes \(photo.companions.count) companion files."
    panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.canCreateDirectories = true; panel.prompt = "Export Here"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    guard !isClosing, let feature = previews.files.exporter, feature.isActive else { return }
    let sourceRoot = rootURL
    isExporting = true
    do {
      try presentation.task { [self] in
        defer { isExporting = false }
        do {
          let plan = try await feature.plan(photo, root: sourceRoot, folder: destination)
          try Task.checkCancellation()
          guard !isClosing, feature.isActive else { return }
          if !plan.replacementNames.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace exported files?"
            alert.informativeText = "These files and all their metadata will be replaced:\n" + plan.replacementNames.joined(separator: "\n")
            alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
          }
          try Task.checkCancellation()
          guard !isClosing else { return }
          try await feature.export(plan, root: sourceRoot)
          if !isClosing { showNotice("Exported to \(destination.lastPathComponent)") }
        } catch { if !isClosing { errorMessage = error.localizedDescription } }
      }
    } catch { isExporting = false; if !isClosing { errorMessage = error.localizedDescription } }
  }

  /// Exports an exact copy. `replacing` is true only when the person agreed to replace a file at `destination`;
  /// otherwise a file that appears there meanwhile is reported, not replaced.
  public func export(_ photo: PhotoItem, to destination: URL, replacing: Bool) async {
    guard !isClosing, !isExporting else { return }
    isExporting = true
    let sourceRoot = rootURL
    defer { isExporting = false }
    do {
      try await previews.start()
      guard !isClosing, let feature = previews.files.exporter else { return }
      try await feature.copy(photo, root: sourceRoot, to: destination, replacing: replacing)
      if !isClosing { showNotice("Exported exact copy to \(destination.lastPathComponent)") }
    } catch { if !isClosing { errorMessage = "Could not export \(photo.name): \(error.localizedDescription)" } }
  }

  private func activate(url: URL, record: LibraryRootInfo) async {
    guard !isClosing, let scanning = previews.library.scanning, scanning.isActive else { return }
    let token = UUID()
    scanTask?.cancel(); scanGeneration = token
    await localFolders?.shutdown()
    await previews.retireSelection()
    guard scanGeneration == token, !isClosing, scanning.isActive else { return }
    localTreeSubscription = nil
    showsOpenChooser = false
    resetRemoteSession()
    do {
      guard let catalog = previews.library.catalog else { throw CancellationError() }
      try catalog.activate(url, rootID: record.id)
    } catch { errorMessage = error.localizedDescription; return }
    rootURL = url.resolvingSymlinksInPath()
    rootName = record.displayName
    activeRootID = record.id
    rootUnavailable = false
    isScanning = false
    selectedFolderPath = ""
    filter = .all
    fileTypeFilter = .all
    folderIsSelected = true
    await settlePreferences()
    guard scanGeneration == token, !isClosing, scanning.isActive else { return }
    viewMode = previews.preferences.value.layout(for: record.id)
    isFocusMode = false
    photos = []
    rootFolder = nil
    clearSelection()
    loadFavorites(rootID: record.id)
    loadChangeState(rootID: record.id)
    let tree: LocalFolderIndex
    do { tree = try scanning.makeIndex(root: rootURL!, rootID: record.id) }
    catch { errorMessage = error.localizedDescription; return }
    installLocalTree(tree)
    if viewMode == .contactSheet { await scan(rootURL: rootURL!, rootID: record.id, preserveSelection: nil) }
    do {
      let result = try await tree.load("")
      guard localFolders === tree else { return }
      if rootFolder == nil { rootFolder = result.rootFolder }
      ensureValidSelection(reload: true)
    } catch {
      if !isClosing, localFolders === tree, !tree.isStopped { errorMessage = error.localizedDescription }
    }
  }

  private func scan(rootURL: URL, rootID: UUID, preserveSelection: PhotoItem.ID?) async {
    // A completed old scan is never allowed to commit into a newer root/refresh.
    guard !isClosing, activeRootID == rootID, self.rootURL == rootURL,
          let scanning = previews.library.scanning, scanning.isActive else { return }
    scanTask?.cancel()
    let token = UUID()
    scanGeneration = token
    isScanning = true
    previews.clearPlayback()
    let task = Task { try await scanning.scan(root: rootURL, rootID: rootID) }
    scanTask = task
    do {
      let result = try await task.value
      guard scanGeneration == token, activeRootID == rootID else { return }
      photos = result.files
      rootFolder = result.rootFolder
      rootUnavailable = false
      isScanning = false
      recordBaselines(scanned: result.files)
      if !selectedFolderPath.isEmpty, !containsFolder(selectedFolderPath, in: result.rootFolder) { selectedFolderPath = "" }
      selectionID = preserveSelection
      ensureValidSelection(reload: true)
      if !result.warnings.isEmpty { errorMessage = result.warnings.prefix(8).joined(separator: "\n\n") }
    } catch {
      guard scanGeneration == token, activeRootID == rootID else { return }
      isScanning = false
      if !(error is CancellationError), previews.library.canScan, let record = record(rootID) { makeUnavailable(record: record, url: rootURL) }
    }
  }

  private func containsFolder(_ path: String, in node: FolderNode) -> Bool {
    node.relativePath == path || node.children.contains { containsFolder(path, in: $0) }
  }
  private func prepareSelection(_ photo: PhotoItem) {
    originalTask?.cancel(); originalPreview = nil; isLoadingOriginal = false
    _ = try? presentation.task { [previews] in await previews.media.pin(photo.remote == nil ? nil : photo) }
    previews.clearPlayback()
    loadMetadata(for: photo)
    if !selectionMissing && (viewMode == .inspect || (photo.remote != nil && photo.format.isVideo)) { previews.preparePlayback(photo) }
  }
  private func loadMetadata(for photo: PhotoItem) {
    metadataTask?.cancel()
    let previews = previews
    metadata = ImageMetadata(identity: [MetadataRow(label: "Type", value: photo.format.rawValue),
      MetadataRow(label: "File size", value: ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))])
    metadataTask = try? presentation.task { [weak self] in
      guard let value = try? await previews.media.readMetadata(photo) else { return }
      guard !Task.isCancelled, self?.selectedPhoto?.metadataContentID == photo.metadataContentID else { return }
      self?.metadata = value
    }
  }
  private func ensureValidSelection(reload: Bool) {
    let items = visiblePhotos
    guard let first = items.first else { clearSelection(); return }
    batchSelection.reconcile(with: items.map(\.id))
    let photo = items.first(where: { $0.id == selectionID && (isSelecting || batchSelection.ids.contains($0.id)) })
      ?? items.first(where: { $0.id == batchSelection.currentID }) ?? first
    batchSelection.preview(photo.id, keepingSelection: isSelecting)
    if reload { selectionID = nil }
    preview(photo)
  }
  private func clearSelection() {
    previews.clearPlayback()
    selectionID = nil
    batchSelection.replace(with: nil)
    selectionMissing = false
    metadataTask?.cancel()
    metadata = ImageMetadata()
  }
  private func makeUnavailable(record: LibraryRootInfo, url: URL? = nil) {
    resetRemoteSession()
    localFolders?.stop(); localFolders = nil; localTreeSubscription = nil
    previews.library.closeLocalRoot()
    scanGeneration = UUID()
    scanTask?.cancel()
    isScanning = false
    clearSelection()
    photos = []
    rootFolder = nil
    rootName = record.displayName
    activeRootID = record.id
    rootURL = url
    rootUnavailable = true
    isFocusMode = false
    viewMode = .inspect
    loadFavorites(rootID: record.id)
    folderBaselines = [:]; openedTimes = [:]; tracksChanges = false
  }
  private func showNotice(_ message: String, action: String? = nil) {
    guard !isClosing else { return }
    noticeTask?.cancel()
    notice = FrameNotice(message: message, actionTitle: action)
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(7))
      guard !Task.isCancelled else { return }
      self?.notice = nil
    }
  }
  private func loadFavorites(rootID: UUID) {
    guard let feature = previews.library.favorites, feature.isActive else { favorites = []; return }
    do { favorites = try feature.favorites(rootID: rootID) }
    catch { errorMessage = "Could not load favorites: \(error.localizedDescription)" }
  }
  private func loadChangeState(rootID: UUID) {
    folderBaselines = [:]; openedTimes = [:]; tracksChanges = false
    guard let feature = previews.library.favorites, feature.isActive,
          let state = try? feature.changeState(rootID: rootID) else { return }
    folderBaselines = state.baselines; openedTimes = state.opened; tracksChanges = true
  }
  /// A folder's first listing sets its baseline from the files in it.
  private func recordBaseline(folder: String, files: [PhotoItem]) {
    guard tracksChanges, folderBaselines[folder] == nil, let rootID = activeRootID,
          let feature = previews.library.favorites, feature.isActive,
          let baseline = try? feature.recordBaseline(rootID: rootID, folder: folder, baseline: ChangeTracking.baseline(of: files)) else { return }
    folderBaselines[folder] = baseline
  }
  /// One folder's own listing: its baseline the first time, and its opened times for files it no longer has.
  /// Only this listing can tell that one of its files is gone; Frame's own moves are kept for Undo and Restore.
  private func recordListing(folder: String, files: [PhotoItem]) {
    let listed = files.filter { $0.archiveID == nil && $0.folderRelativePath == folder }
    recordBaseline(folder: folder, files: listed)
    guard let rootID = activeRootID, !openedTimes.isEmpty, let feature = previews.library.favorites, feature.isActive,
          let dropped = try? feature.pruneOpened(rootID: rootID, folder: folder, keeping: Set(listed.map(\.relativePath))) else { return }
    for key in dropped { openedTimes.removeValue(forKey: key) }
  }
  /// A whole-library scan sets baselines for folders not listed before. It never drops opened times: it skips
  /// package contents the tree shows, so absence from it proves nothing.
  private func recordBaselines(scanned files: [PhotoItem]) {
    guard tracksChanges else { return }
    let folders = Dictionary(grouping: files.filter { $0.archiveID == nil }, by: \.folderRelativePath)
    for (folder, items) in folders where folderBaselines[folder] == nil { recordBaseline(folder: folder, files: items) }
  }
  private func recordRemoteBaselines() {
    guard tracksChanges, !isClosing, let tree = remoteFolders else { return }
    for (path, node) in tree.nodes where node.isLoaded && folderBaselines[path] == nil {
      // A folder whose listing has left the cache is skipped rather than given an empty baseline; a cached empty
      // listing gets the same baseline as opening the folder would give it.
      if let files = tree.cachedFiles(at: path) { recordBaseline(folder: path, files: files) }
    }
  }
  /// Keeps the opened times of files Frame is about to move to the Trash or the Archive.
  private func holdOpened(_ targets: [PhotoItem]) {
    guard tracksChanges, let feature = previews.library.favorites, feature.isActive else { return }
    let keys = Set(targets.flatMap { photo in
      [photo.favoriteID] + photo.companions.map { FavoriteRecord.makeKey(rootID: photo.rootID, relativePath: $0.relativePath) }
    }).intersection(openedTimes.keys)
    try? feature.holdOpened(keys: keys)
  }
  /// Drops the opened times of files a remote Delete removed for good. An archived file's entry, held since it was
  /// archived, goes too unless a file listed at its path since has taken it over.
  private func forgetOpened(_ deleted: [PhotoItem]) {
    guard tracksChanges, let feature = previews.library.favorites, feature.isActive else { return }
    func keys(_ photos: [PhotoItem]) -> Set<String> {
      Set(photos.flatMap { photo in
        [photo.favoriteID] + photo.companions.map { FavoriteRecord.makeKey(rootID: photo.rootID, relativePath: $0.relativePath) }
      })
    }
    guard let dropped = try? feature.forgetOpened(keys: keys(deleted.filter { $0.archiveID == nil }),
                                                  heldKeys: keys(deleted.filter { $0.archiveID != nil })) else { return }
    for key in dropped { openedTimes.removeValue(forKey: key) }
  }
  private func record(_ id: UUID) -> LibraryRootInfo? { try? previews.library.catalog?.record(id) }
  private func reloadRecents() {
    guard let catalog = previews.library.catalog, catalog.isActive else { return }
    do { recentFolders = try catalog.recents() }
    catch { errorMessage = "Could not load folders: \(error.localizedDescription)" }
  }
  private func metadataReaderChanged() {
    guard !isClosing else { return }
    let metadataGeneration = selectedPhoto.flatMap { previews.media.metadataGeneration(for: $0) }
    guard metadataGeneration != self.metadataGeneration else { return }
    self.metadataGeneration = metadataGeneration
    metadataTask?.cancel()
    if metadataGeneration != nil, let photo = selectedPhoto { loadMetadata(for: photo) }
  }
  /// The folder, its filters or its files changed: the list is recomputed and an active search runs again.
  private func scopeChanged() {
    visibleCache = nil; kindCountsCache = nil; folderFileCountCache = nil
    guard !searchQuery.isEmpty else { return }
    scheduleSearch()
  }
  /// Searches the current scope after a short pause, superseding any earlier search. A result is applied
  /// only if no newer search has started, and the selection is then kept inside the list as a filter
  /// change keeps it. Without a search feature for this world the search ends.
  private func scheduleSearch() {
    searchTask?.cancel()
    searchTask = nil
    searchGeneration = UUID()
    guard !isClosing else { return }
    guard let feature = searchFeature else {
      removeSearch()
      return
    }
    let generation = searchGeneration
    let query = searchQuery
    searchTask = try? presentation.task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(200))
      } catch {
        return
      }
      guard let self, searchGeneration == generation else { return }
      guard let matches = try? await feature.matches(in: searchScope, query: query) else { return }
      guard !Task.isCancelled, !isClosing, searchGeneration == generation else { return }
      searchMatches = matches
      ensureValidSelection(reload: false)
    }
  }
  /// Ends the search: the query, the filter and any pending search go together. If a result had narrowed
  /// the list, the selection is repaired as a filter change repairs it.
  private func removeSearch() {
    let narrowed = searchMatches != nil
    searchTask?.cancel()
    searchTask = nil
    searchGeneration = UUID()
    searchQuery = ""
    searchMatches = nil
    if narrowed {
      ensureValidSelection(reload: false)
    }
  }
  /// A search feature appeared, was replaced or went away. Only the one for the world being shown matters:
  /// the views are told at once, so the field comes and goes with it.
  private func searchFeatureChanged(remote: Bool) {
    guard !isClosing, isRemote == remote else { return }
    objectWillChange.send()
    guard !searchQuery.isEmpty else { return }
    scheduleSearch()
  }
  private func catalogBecameAvailable() {
    guard !isClosing else { return }
    reloadRecents()
  }
  private func favoritesBecameAvailable() {
    guard !isClosing, let activeRootID else { return }
    loadFavorites(rootID: activeRootID)
    if !rootUnavailable { loadChangeState(rootID: activeRootID) }
  }
  private func scanningBecameAvailable() {
    guard !isClosing, !isRemote, !rootUnavailable, let rootURL, let activeRootID,
          let feature = previews.library.scanning else { return }
    do {
      try previews.library.catalog?.activate(rootURL, rootID: activeRootID)
      let tree = try feature.makeIndex(root: rootURL, rootID: activeRootID)
      let path = selectedFolderPath
      localFolders?.stop(); installLocalTree(tree); tree.reveal(path)
      _ = try? presentation.task { [weak self, weak tree] in
        guard let self, let tree else { return }
        do { _ = try await tree.load(path) }
        catch { if !isClosing, localFolders === tree, !tree.isStopped { errorMessage = error.localizedDescription } }
      }
    } catch { errorMessage = error.localizedDescription }
  }
  private func installLocalTree(_ tree: LocalFolderIndex) {
    localFolders = tree
    localTreeSubscription = tree.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    tree.onChange = { [weak self, weak tree] path, result in
      guard let self, !isClosing, self.localFolders === tree else { return }
      self.installDirectory(path, result)
    }
    tree.onFilesChanged = { [weak self, weak tree] in
      guard let self, !isClosing, self.localFolders === tree else { return }
      self.documentRevision += 1
    }
  }
}
