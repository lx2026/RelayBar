import PreviewSupport
import AppKit
import Combine
import FrameKit
import HouseStyle
import SwiftUI

/// Icons mode: the folder on show as one grid of folder tiles and thumbnails, under a row with its filters,
/// size and the selection's actions.
struct IconsWorkspace: View {
  @ObservedObject var store: LibraryStore
  let leading: LeadingControls
  var body: some View {
    VStack(spacing: 0) {
      IconsRow(store: store, leading: leading)
      if store.visiblePhotos.isEmpty && store.gridFolders.isEmpty {
        EmptyFilesView(store: store)
      } else {
        NativeContactSheet(store: store)
      }
      let hidden = store.hiddenCount(in: store.selectedFolderPath)
      if hidden > 0, store.filter != .archive {
        HStack {
          Text(FolderListing.hiddenLabel(hidden))
          Spacer()
          Button(FolderListing.show) { store.revealHidden(in: store.selectedFolderPath) }
        }.padding(8)
      }
    }
  }
}

private struct IconsRow: View {
  @ObservedObject var store: LibraryStore
  let leading: LeadingControls
  @State private var showsScanDetails = false
  var body: some View {
    // The kind chips, then the item count, give way first when the column is narrow.
    ViewThatFits(in: .horizontal) {
      row(chips: true, count: true)
      row(chips: false, count: true)
      row(chips: false, count: false)
    }
    .padding(.leading, leading == .none ? FrameMetrics.readerLeading : FrameMetrics.inset)
    .padding(.trailing, FrameMetrics.readerTrailing)
    .frame(height: FrameMetrics.topRowHeight)
    .background(WindowDragArea())
  }

  private func row(chips: Bool, count: Bool) -> some View {
    HStack(spacing: 6) {
      LeadingRowControls(store: store, leading: leading)
      Text(store.shownFolderName).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        .padding(.trailing, 2)
      if count {
        Text(itemsLabel).font(.system(size: 12).monospacedDigit()).foregroundStyle(FramePalette.muted)
          .lineLimit(1).fixedSize().padding(.trailing, 10)
      }
      if chips { KindChips(store: store) }
      Spacer(minLength: 12)
      subfolders
      Button(store.isSelecting ? "Done" : "Select", action: store.toggleSelectMode)
        .buttonStyle(TextButtonStyle(isOn: store.isSelecting)).disabled(store.visiblePhotos.isEmpty || store.isFileOperation)
      // Rounded by hand: a stepped slider draws a tick for every step.
      Slider(value: Binding(get: { store.thumbnailWidth }, set: { value in
        Task { await store.setThumbnailWidth((value / 10).rounded() * 10) }
      }), in: ContactSheetMetrics.thumbnailRange)
        .controlSize(.small).frame(width: 84).padding(.leading, 4)
        .accessibilityLabel("Thumbnail size")
        .accessibilityValue("\(Int(store.thumbnailWidth)) points").disabled(store.isFileOperation)
      if !store.actionPhotos.isEmpty {
        Hairline(vertical: true).frame(height: 18).padding(.horizontal, 6)
        if let count = store.selectionCountLabel {
          Text(count).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize().padding(.trailing, 4)
        }
        FileActions(store: store)
      }
    }
  }

  private var itemsLabel: String {
    let files = store.visiblePhotos.count
    if store.hasFileFilters || store.searchMatchCount != nil { return "\(files) of \(store.folderFileCount) items" }
    let total = files + store.gridFolders.count
    return "\(total) \(total == 1 ? "item" : "items")"
  }

  @ViewBuilder private var subfolders: some View {
    if store.filter != .archive {
      HStack(spacing: 6) {
        Toggle("Subfolders", isOn: Binding(get: { store.includesSubfolders }, set: { value in Task { await store.setIncludesSubfolders(value) } }))
          .toggleStyle(.checkbox).controlSize(.small).disabled(store.isFileOperation).fixedSize()
        if store.isScanningSubfolders {
          ProgressView().controlSize(.mini)
          Button("Stop", action: store.stopRemoteScan).buttonStyle(.plain).help("Stop scanning (Escape)")
        } else if store.remoteScanIssue != nil {
          Button { showsScanDetails.toggle() } label: { Image(systemName: "exclamationmark.circle") }
            .buttonStyle(.plain).help("Some subfolders have not been read").accessibilityLabel("Scan incomplete")
            .popover(isPresented: $showsScanDetails) {
              VStack(alignment: .leading, spacing: 12) {
                Text(store.remoteScanIssue ?? "").textSelection(.enabled)
                Button("Retry") { showsScanDetails = false; store.refresh() }
              }.font(.callout).padding(16).frame(width: 320)
            }
        }
      }
      .font(.system(size: 12)).padding(.trailing, 4)
    }
  }
}

/// All, Documents, Images and Video: the same kind filter as the footer's menu, with the folder's counts.
private struct KindChips: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    let counts = store.kindCounts
    let folders = store.includesSubfolders ? 0 : store.subfolders.count
    HStack(spacing: 2) {
      chip(.all, "All", (counts[.all] ?? 0) + folders)
      chip(.documents, "Documents", counts[.documents] ?? 0)
      chip(.images, "Images", counts[.images] ?? 0)
      chip(.videos, "Video", counts[.videos] ?? 0)
    }
    .disabled(store.isFileOperation)
  }
  @ViewBuilder private func chip(_ kind: FileTypeFilter, _ title: String, _ count: Int) -> some View {
    let isOn = store.fileTypeFilter == kind
    if isOn || kind == .all || count > 0 {
      Button { store.setFileTypeFilter(kind) } label: {
        HStack(spacing: 4) {
          Text(title).font(.system(size: 12, weight: isOn ? .semibold : .regular))
          Text("\(count)").font(.system(size: 11).monospacedDigit()).opacity(0.85)
        }
        .foregroundStyle(isOn ? FramePalette.paper : FramePalette.muted)
        .padding(.horizontal, 9).frame(height: 22)
        .background(Capsule().fill(isOn ? FramePalette.ink : .clear))
        .contentShape(Capsule())
        .fixedSize()
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(title), \(count)").accessibilityAddTraits(isOn ? .isSelected : [])
    }
  }
}

/// A small text button in a top row, filled while it is on.
struct TextButtonStyle: ButtonStyle {
  var isOn = false
  func makeBody(configuration: Configuration) -> some View {
    TextButtonBody(configuration: configuration, isOn: isOn)
  }
}

private struct TextButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let isOn: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false
  var body: some View {
    configuration.label
      .font(.system(size: 12, weight: isOn ? .semibold : .regular))
      .foregroundStyle(isOn ? FramePalette.ink : FramePalette.muted)
      .padding(.horizontal, 8).frame(height: 24)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isOn || (enabled && (hovered || configuration.isPressed)) ? FramePalette.fill : .clear))
      .contentShape(Rectangle())
      .opacity(enabled ? 1 : 0.4)
      .onHover { hovered = $0 }
  }
}

struct EmptyFilesView: View {
  @ObservedObject var store: LibraryStore
  private var title: String {
    if store.isReadingFolder { return "Reading folder…" }
    if store.folderReadError != nil { return "Folder unavailable" }
    if store.isScanningSubfolders { return "Scanning…" }
    if store.hasFileFilters || store.searchMatchCount != nil { return "No matching files" }
    return store.filter == .archive ? "Archive is empty" : "No files in this folder"
  }
  private var detail: String {
    if store.isReadingFolder { return "" }
    if let error = store.folderReadError { return error }
    if store.hasFileFilters { return "Change the filter to see other files." }
    if store.searchMatchCount != nil { return "Change the search to see other files." }
    if store.filter != .archive, !store.includesSubfolders, store.folderContainsSubfolders {
      return "Choose a subfolder in the sidebar, or include subfolders."
    }
    return ""
  }
  var body: some View {
    WorkspaceMessage(symbol: store.filter == .archive ? "archivebox" : "folder", title: title, detail: detail) {
      if store.folderReadError != nil, !store.isReadingFolder {
        Button("Retry", action: store.retrySelectedFolder).buttonStyle(FilledButtonStyle())
      } else if store.hasFileFilters || store.searchMatchCount != nil, !store.isReadingFolder {
        Button("Show all files", action: store.clearFileFilters).buttonStyle(FilledButtonStyle())
      }
    }
  }
}

/// Reusable native cells keep selection, marquee, scrolling and range anchors in AppKit. Subfolders come first
/// as tiles that open the folder; they take the keyboard focus but never join the selection.
struct NativeContactSheet: NSViewRepresentable {
  @ObservedObject var store: LibraryStore
  func makeCoordinator() -> Coordinator { Coordinator(store: store) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = OverlayScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let grid = MediaCollectionView()
    grid.isSelectable = true
    grid.allowsMultipleSelection = true
    grid.allowsEmptySelection = true
    // A collection view keeps its background as a layer colour that only light and dark refresh, so it is given the
    // active form's paper, and given it again whenever the form changes.
    grid.backgroundColors = [HousePalette.paper.nsColor(in: HousePalette.form)]
    context.coordinator.paperObservation = NotificationCenter.default.publisher(for: HousePalette.didChangeNotification)
      .sink { [weak grid] _ in grid?.backgroundColors = [HousePalette.paper.nsColor(in: HousePalette.form)] }
    let layout = NSCollectionViewFlowLayout()
    let metrics = ContactSheetMetrics(preferredWidth: store.thumbnailWidth, viewportWidth: 1_000)
    layout.itemSize = NSSize(width: metrics.width, height: metrics.height)
    layout.minimumInteritemSpacing = ContactSheetMetrics.columnGap
    layout.minimumLineSpacing = ContactSheetMetrics.rowGap
    layout.sectionInset = NSEdgeInsets(top: ContactSheetMetrics.topInset, left: ContactSheetMetrics.inset,
                                       bottom: ContactSheetMetrics.bottomInset, right: ContactSheetMetrics.inset)
    grid.collectionViewLayout = layout
    grid.register(MediaCell.self, forItemWithIdentifier: MediaCell.identifier)
    grid.delegate = context.coordinator
    context.coordinator.grid = grid
    context.coordinator.installDataSource(grid)
    grid.onPreview = { [weak coordinator = context.coordinator] index in coordinator?.preview(index) }
    grid.onInspect = { [weak coordinator = context.coordinator] in coordinator?.inspect() }
    grid.onOpenFolder = { [weak coordinator = context.coordinator] index in coordinator?.openFolder(index) }
    grid.onFocusChange = { [weak coordinator = context.coordinator] in coordinator?.updateVisibleThumbnails() }
    grid.onClear = { [weak coordinator = context.coordinator] in coordinator?.clear() }
    grid.onEscape = { [weak store] in store?.escape() }
    grid.onFavorite = { [weak coordinator = context.coordinator] in coordinator?.store.toggleFavorite() }
    grid.onLayoutChange = { [weak coordinator = context.coordinator] in coordinator?.updateVisibleThumbnails() }
    grid.preferredThumbnailWidth = store.thumbnailWidth
    scroll.documentView = grid
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.store = store
    guard let grid = coordinator.grid else { return }
    let photos = store.visiblePhotos
    let folders = store.gridFolders
    coordinator.synchronizing = true
    let scope = store.gridScopeKey
    if scope != coordinator.scopeKey {
      if let old = coordinator.scopeKey { store.gridScrollPositions[old] = view.contentView.bounds.origin.y }
      coordinator.scopeKey = scope
      coordinator.restoreScroll = true
    }
    if photos != coordinator.photos || folders != coordinator.folders {
      coordinator.apply(photos, folders: folders, preservingViewport: !coordinator.restoreScroll)
    }
    grid.blocked = store.isFileOperation
    grid.selectionMode = store.isSelecting
    grid.preferredThumbnailWidth = store.thumbnailWidth
    coordinator.synchronizeSelection()
    coordinator.synchronizing = false
    if coordinator.restoreScroll {
      coordinator.restoreScroll = false
      let offset = store.gridScrollPositions[scope] ?? 0
      DispatchQueue.main.async {
        guard coordinator.scopeKey == scope else { return }
        view.contentView.scroll(to: NSPoint(x: 0, y: offset))
        view.reflectScrolledClipView(view.contentView)
      }
    }
  }
  static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
    if let key = coordinator.scopeKey { coordinator.store.gridScrollPositions[key] = view.contentView.bounds.origin.y }
    for item in coordinator.grid?.visibleItems() ?? [] { (item as? MediaCell)?.cancelLoad() }
  }
  @MainActor final class Coordinator: NSObject, NSCollectionViewDelegate {
    var store: LibraryStore
    var photos: [PhotoItem] = []
    var folders: [FolderTile] = []
    var byID: [String: PhotoItem] = [:]
    var folderByID: [String: FolderTile] = [:]
    var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
    weak var grid: MediaCollectionView?
    var paperObservation: AnyCancellable?
    var synchronizing = false
    var applyingSnapshot = false
    var snapshotGeneration = 0
    var lastPreviewID: String?
    var scopeKey: String?
    var restoreScroll = true
    init(store: LibraryStore) { self.store = store }
    /// Folder identifiers cannot collide with file identifiers, which always start with the root's UUID.
    static func folderID(_ tile: FolderTile) -> String { "folder\u{1F}" + tile.path }
    private var offset: Int { folders.count }
    func installDataSource(_ grid: MediaCollectionView) {
      dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: grid) { [weak self, weak grid] collection, path, id in
        guard let self, let grid else { return nil }
        let item = collection.makeItem(withIdentifier: MediaCell.identifier, for: path) as! MediaCell
        if let tile = folderByID[id] {
          item.configureFolder(tile, active: isActive(path.item))
        } else if let photo = byID[id] {
          item.configure(photo, favorite: store.isFavorite(photo), changed: store.isChanged(photo), active: isActive(path.item),
            selecting: store.isSelecting, pixelSize: grid.thumbnailPixels, previews: store.previews, companion: store.companionDescription(photo))
        } else { return nil }
        item.onActivate = { [weak self, weak grid] in
          guard let self, let index = gridIndex(of: id) else { return }
          grid?.activateItem(at: index)
        }
        item.onToggle = { [weak self] in
          guard let self, let photo = byID[id] else { return }
          store.select(photo); store.toggleCurrentSelection()
        }
        return item
      }
    }
    private func gridIndex(of id: String) -> Int? {
      if let index = folders.firstIndex(where: { Self.folderID($0) == id }) { return index }
      return photos.firstIndex { $0.id == id }.map { $0 + offset }
    }
    /// The focused tile: a folder the keyboard moved to, otherwise the file on show.
    private func isActive(_ index: Int) -> Bool {
      if let current = grid?.currentIndex, current < offset { return index == current }
      let photoIndex = index - offset
      return photos.indices.contains(photoIndex) && photos[photoIndex].id == store.selectionID
    }
    func apply(_ next: [PhotoItem], folders nextFolders: [FolderTile], preservingViewport: Bool) {
      guard let grid, let scroll = grid.enclosingScrollView else { return }
      let oldIDs = folders.map(Self.folderID) + photos.map(\.id)
      let newIDs = nextFolders.map(Self.folderID) + next.map(\.id)
      let top = grid.indexPathsForVisibleItems().min { $0.item < $1.item }
      let oldTop = top.flatMap { oldIDs.indices.contains($0.item) ? oldIDs[$0.item] : nil }
      let offsetY = top.flatMap { grid.collectionViewLayout?.layoutAttributesForItem(at: $0) }
        .map { scroll.contentView.bounds.minY - $0.frame.minY } ?? 0
      photos = next
      folders = nextFolders
      byID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
      folderByID = Dictionary(nextFolders.map { (Self.folderID($0), $0) }, uniquingKeysWith: { first, _ in first })
      grid.folderCount = nextFolders.count
      guard oldIDs != newIDs else { return }
      grid.resetAnchor()
      var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
      snapshot.appendSections([0]); snapshot.appendItems(newIDs)
      applyingSnapshot = true
      snapshotGeneration += 1
      let generation = snapshotGeneration
      // Apply a real diff without animating hundreds of shifting cells.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        dataSource.apply(snapshot, animatingDifferences: !oldIDs.isEmpty) { [weak self] in
          guard let self, snapshotGeneration == generation else { return }
          applyingSnapshot = false
          grid.layoutSubtreeIfNeeded()
          if preservingViewport,
             let anchor = MediaSelection.nextPreview(in: oldIDs, current: oldTop, removing: Set(oldIDs).subtracting(newIDs)),
             let index = newIDs.firstIndex(of: anchor),
             let attributes = grid.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
            let y = min(max(0, attributes.frame.minY + offsetY), max(0, grid.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
          }
          synchronizing = true
          synchronizeSelection()
          synchronizing = false
        }
      }
    }
    func synchronizeSelection() {
      guard !applyingSnapshot, let grid else { return }
      let offset = offset
      let indexes = Set(photos.enumerated().compactMap { store.batchSelection.ids.contains($0.element.id) ? IndexPath(item: $0.offset + offset, section: 0) : nil })
      if grid.selectionIndexPaths != indexes { grid.selectionIndexPaths = indexes }
      let folderFocused = grid.currentIndex.map { $0 < offset } ?? false
      if !folderFocused || lastPreviewID != store.selectionID {
        grid.currentIndex = photos.firstIndex { $0.id == store.selectionID }.map { $0 + offset }
      }
      if lastPreviewID != store.selectionID {
        lastPreviewID = store.selectionID
        if let index = grid.currentIndex,
           let attributes = grid.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
          grid.scrollToVisible(attributes.frame)
        }
      }
      updateVisibleThumbnails()
    }
    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
      indexPaths.filter { $0.item >= offset }
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
      (item as? MediaCell)?.cancelLoad()
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
      configure(item as? MediaCell, at: indexPath.item)
    }
    private func configure(_ cell: MediaCell?, at index: Int) {
      guard let cell else { return }
      if folders.indices.contains(index) {
        cell.configureFolder(folders[index], active: isActive(index))
      } else if photos.indices.contains(index - offset) {
        let photo = photos[index - offset]
        cell.configure(photo, favorite: store.isFavorite(photo), changed: store.isChanged(photo), active: isActive(index),
          selecting: store.isSelecting, pixelSize: grid?.thumbnailPixels ?? 384, previews: store.previews,
          companion: store.companionDescription(photo))
      }
    }
    func updateVisibleThumbnails() {
      guard !applyingSnapshot, let grid else { return }
      for path in grid.indexPathsForVisibleItems() { configure(grid.item(at: path) as? MediaCell, at: path.item) }
    }
    func syncSelection() {
      guard !synchronizing, !applyingSnapshot, let grid, !store.isFileOperation else { return }
      let offset = offset
      let ids = Set(grid.selectionIndexPaths.compactMap { path -> String? in
        photos.indices.contains(path.item - offset) ? photos[path.item - offset].id : nil
      })
      let current = grid.currentIndex.flatMap { photos.indices.contains($0 - offset) ? photos[$0 - offset].id : nil }
      store.updateGridSelection(ids, currentID: current)
    }
    func preview(_ index: Int) {
      guard photos.indices.contains(index - offset), let grid else { return }
      grid.currentIndex = index
      syncSelection()
    }
    func inspect() {
      guard let photo = store.selectedPhoto else { return }
      store.inspect(photo)
    }
    func openFolder(_ index: Int) {
      guard folders.indices.contains(index) else { return }
      store.selectFolder(folders[index].path)
    }
    func clear() { grid?.deselectAll(nil); syncSelection() }
  }
}

@MainActor final class MediaCollectionView: NSCollectionView {
  var onPreview: ((Int) -> Void)?
  var onInspect: (() -> Void)?
  var onOpenFolder: ((Int) -> Void)?
  var onFocusChange: (() -> Void)?
  var onClear: (() -> Void)?
  var onEscape: (() -> Void)?
  var onFavorite: (() -> Void)?
  var onLayoutChange: (() -> Void)?
  /// Folder tiles lead the grid; they are focused and opened, never selected.
  var folderCount = 0
  var preferredThumbnailWidth: Double = ContactSheetMetrics.defaultThumbnailWidth {
    didSet { if preferredThumbnailWidth != oldValue { resizeThumbnails() } }
  }
  private var layoutGeneration = 0
  private var metrics: ContactSheetMetrics {
    ContactSheetMetrics(preferredWidth: preferredThumbnailWidth, viewportWidth: bounds.width)
  }
  var thumbnailPixels: Int { metrics.thumbnailPixels(scale: Double(window?.backingScaleFactor ?? 2)) }
  var currentIndex: Int?
  private var rangeAnchor = SelectionRangeAnchor()
  private var doubleClickSelection: (indexes: Set<IndexPath>, index: Int, time: TimeInterval)?
  var blocked = false
  var selectionMode = false
  func resetAnchor() {
    layoutGeneration += 1 // A queued resize must not restore an anchor from a previous scope.
    rangeAnchor.reset(); currentIndex = nil; doubleClickSelection = nil
  }
  func activateItem(at index: Int) {
    guard !blocked, (0..<numberOfItems(inSection: 0)).contains(index) else { return }
    window?.makeFirstResponder(self)
    if index < folderCount { onOpenFolder?(index); return }
    choose(index, extending: false, previewOnly: selectionMode)
  }
  override var acceptsFirstResponder: Bool { true }
  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { resizeThumbnails() }
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    onLayoutChange?()
  }
  private func resizeThumbnails() {
    guard bounds.width > 0, let layout = collectionViewLayout as? NSCollectionViewFlowLayout else { return }
    let size = NSSize(width: metrics.width, height: metrics.height)
    guard size != layout.itemSize else { return }
    let top = indexPathsForVisibleItems().min { $0.item < $1.item }
    let offset = top.flatMap { layout.layoutAttributesForItem(at: $0) }.map {
      (enclosingScrollView?.contentView.bounds.minY ?? 0) - $0.frame.minY
    } ?? 0
    layout.itemSize = size
    layout.invalidateLayout()
    layoutGeneration += 1
    let generation = layoutGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self, generation == layoutGeneration else { return }
      layoutSubtreeIfNeeded()
      if let top, top.item < numberOfItems(inSection: 0), let scroll = enclosingScrollView,
         let attributes = layout.layoutAttributesForItem(at: top) {
        let y = min(max(0, attributes.frame.minY + offset), max(0, bounds.height - scroll.contentSize.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      onLayoutChange?()
    }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // A grid rebuilt while someone types elsewhere must not take the keyboard from that text control.
    guard let window, !TypingGuard.isEditingText(window.firstResponder) else { return }
    window.makeFirstResponder(self)
  }
  override func mouseDown(with event: NSEvent) {
    guard !blocked else { return }
    window?.makeFirstResponder(self)
    let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
    if let index, index < folderCount {
      doubleClickSelection = nil
      if event.clickCount >= 2 { onOpenFolder?(index); return }
      currentIndex = index
      onFocusChange?()
      return
    }
    if let index {
      if event.clickCount == 2, let previous = doubleClickSelection, previous.index == index,
         event.timestamp - previous.time <= NSEvent.doubleClickInterval {
        selectionIndexPaths = previous.indexes
        currentIndex = index
        onPreview?(index)
        doubleClickSelection = nil
        onInspect?()
        return
      }
      if event.clickCount == 1 && selectionIndexPaths.count > 1
        && selectionIndexPaths.contains(IndexPath(item: index, section: 0))
        && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
        doubleClickSelection = (selectionIndexPaths, index, event.timestamp)
      } else { doubleClickSelection = nil }
      choose(index, extending: event.modifierFlags.contains(.shift), toggling: event.modifierFlags.contains(.command),
        previewOnly: selectionMode && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command))
      if event.clickCount == 2 { onInspect?() }
    } else {
      super.mouseDown(with: event) // Native marquee and blank-space behavior.
    }
  }
  private func choose(_ index: Int, extending: Bool, toggling: Bool = false, previewOnly: Bool = false) {
    if index < folderCount {
      currentIndex = index
      onFocusChange?()
      return
    }
    if !previewOnly {
      if extending {
        guard let bounds = rangeAnchor.range(to: index, current: currentIndex, count: numberOfItems(inSection: 0)) else { return }
        let range = Set(bounds.filter { $0 >= folderCount }.map { IndexPath(item: $0, section: 0) })
        selectionIndexPaths = toggling ? selectionIndexPaths.union(range) : range
      } else if toggling {
        var selection = selectionIndexPaths
        let path = IndexPath(item: index, section: 0)
        if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
        selectionIndexPaths = selection
        rangeAnchor.set(index)
      } else {
        selectionIndexPaths = [IndexPath(item: index, section: 0)]
        rangeAnchor.set(index)
      }
    }
    currentIndex = index
    onPreview?(index)
  }
  override func keyDown(with event: NSEvent) {
    guard !blocked else { return }
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let onFolder = currentIndex.map { $0 < folderCount } ?? false
    if event.keyCode == 53 && flags.isEmpty { onEscape?(); return }
    if event.keyCode == 36 && flags.isEmpty {
      if onFolder, let currentIndex { onOpenFolder?(currentIndex) } else { onInspect?() }
      return
    }
    if event.charactersIgnoringModifiers?.lowercased() == "g", flags.isEmpty { if !onFolder { onInspect?() }; return }
    if event.charactersIgnoringModifiers?.lowercased() == "f", flags.isEmpty { onFavorite?(); return }
    if event.charactersIgnoringModifiers?.lowercased() == "a", flags == [.command, .shift] { onClear?(); return }
    if event.charactersIgnoringModifiers?.lowercased() == "a", flags == .command {
      let count = numberOfItems(inSection: 0)
      selectionIndexPaths = Set((min(folderCount, count)..<count).map { IndexPath(item: $0, section: 0) })
      if count > folderCount { onPreview?(currentIndex.map { $0 < folderCount ? folderCount : $0 } ?? folderCount) }
      return
    }
    if event.keyCode == 49 { return } // Browse is a static preview; AVKit owns playback in Files mode.
    if [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) {
      let count = numberOfItems(inSection: 0)
      guard count > 0 else { return }
      let columns = metrics.columns
      let rows = metrics.visibleRows(in: Double(enclosingScrollView?.contentView.bounds.height ?? 400))
      let current = currentIndex ?? 0
      let index: Int
      switch event.keyCode {
      case 123: index = current - 1
      case 124: index = current + 1
      case 125: index = current + columns
      case 126: index = current - columns
      case 115: index = 0
      case 119: index = count - 1
      case 116: index = current - columns * rows
      default: index = current + columns * rows
      }
      let destination = min(count - 1, max(0, index))
      choose(destination, extending: flags.contains(.shift), toggling: flags.contains(.command) && flags.contains(.shift),
        previewOnly: selectionMode && flags.isEmpty)
      scrollToItems(at: [IndexPath(item: destination, section: 0)], scrollPosition: .nearestVerticalEdge)
      return
    }
    super.keyDown(with: event)
  }
  override func drawFocusRingMask() { bounds.fill() }
  override var focusRingMaskBounds: NSRect { bounds }
}

@MainActor private final class MediaCell: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("FrameMediaCell")
  private var task: Task<Void, Never>?
  private var contentID: String?
  private var previewSettingsID: String?
  private var previewSession: PreviewSession<FramePreviewContent>?
  private var requestedPixels = 0
  private var loadedPixels = 0
  private var card: ThumbnailCard { view as! ThumbnailCard }
  var onActivate: (() -> Void)? {
    get { card.onActivate }
    set { card.onActivate = newValue }
  }
  var onToggle: (() -> Void)? {
    get { card.onToggle }
    set { card.onToggle = newValue }
  }
  override func loadView() { view = ThumbnailCard() }
  override var isSelected: Bool { didSet { card.selected = isSelected } }
  override func prepareForReuse() { super.prepareForReuse(); cancelLoad(); contentID = nil; loadedPixels = 0 }
  func cancelLoad() {
    task?.cancel(); task = nil; requestedPixels = 0
    let session = previewSession; previewSession = nil; session?.invalidate()
    if let session { Task { await session.close() } }
  }
  func configureFolder(_ tile: FolderTile, active: Bool) {
    if contentID != nil || card.kind != .folder {
      cancelLoad(); contentID = nil; loadedPixels = 0
      card.picture = nil
    }
    card.kind = .folder
    card.title = tile.name
    card.favorite = false
    card.changed = false
    card.chip = nil
    card.marker = nil
    card.selecting = false
    card.active = active
    card.setAccessibilityLabel("\(tile.name), folder")
    card.toolTip = tile.path
  }
  func configure(_ photo: PhotoItem, favorite: Bool, changed: Bool, active: Bool, selecting: Bool, pixelSize: Int,
                 previews: FrameComposition, companion: String?) {
    let settingsID = previews.settingsID(for: photo)
    card.favorite = favorite
    card.changed = changed
    card.selecting = selecting
    card.active = active
    card.title = photo.name
    card.setAccessibilityLabel(photo.name + (companion.map { ", " + $0 } ?? "") + (photo.companions.isEmpty ? "" : ", \(photo.companions.count) companion files")
      + (changed ? ", Changed since last opened" : "") + (active ? ", active preview" : ""))
    card.check.setAccessibilityLabel("Select \(photo.name)")
    card.toolTip = photo.exportMembers.map(\.relativePath).joined(separator: "\n")
    if let companion { card.toolTip = (card.toolTip ?? "") + "\n" + companion }
    card.marker = photo.companionOwnerID != nil ? "Companion" : photo.companions.isEmpty ? nil : "{ }"
    if contentID != photo.contentID || previewSettingsID != settingsID {
      cancelLoad()
      contentID = photo.contentID
      previewSettingsID = settingsID
      loadedPixels = 0
      card.picture = nil
      card.chip = photo.format.isVideo ? .duration(nil) : nil
    }
    if photo.format.isDocument {
      cancelLoad()
      card.kind = .document(ThumbnailCard.Page(photo))
      card.chip = .kind(photo.kindChip)
      card.picture = nil
      return
    }
    card.kind = .media
    guard loadedPixels < pixelSize, requestedPixels < pixelSize else { return }
    task?.cancel()
    requestedPixels = pixelSize
    task = Task { [weak self] in
      // Keep the previous pixels visible while dragging; decode only after resizing settles.
      try? await Task.sleep(for: .milliseconds(80))
      guard !Task.isCancelled else { return }
      let session = try? await previews.image(photo, pixels: pixelSize, priority: 1)
      guard !Task.isCancelled, session?.isClosed != true, let self, contentID == photo.contentID, previewSettingsID == settingsID else { await session?.close(); return }
      let old = previewSession; previewSession = session; old?.invalidate(); await old?.close()
      guard !Task.isCancelled, session?.isClosed != true, contentID == photo.contentID, previewSettingsID == settingsID else { await session?.close(); return }
      let id = session?.id
      session?.onClose = { [weak self] in
        guard let self, self.previewSession?.id == id else { return }
        self.previewSession = nil; self.loadedPixels = 0; self.requestedPixels = 0; self.card.picture = nil
      }
      loadedPixels = session == nil ? 0 : pixelSize
      card.picture = session?.content.image.map { NSImage(cgImage: $0, size: .zero) }
      if card.picture == nil { card.placeholder = photo.format.isVideo ? "play.slash" : "photo" }
      if photo.format.isVideo {
        let info = try? await previews.media.videoInfo(photo)
        guard !Task.isCancelled, contentID == photo.contentID else { return }
        card.chip = .duration(info?.durationLabel)
      }
    }
  }
}

/// One tile: a 3:4 well on the stage colour with the picture, page or folder, and the name below it.
@MainActor private final class ThumbnailCard: NSView {
  /// A drawing of a page, so documents read as documents at a glance.
  enum Page: Equatable {
    case markdown, html, json, text
    init(_ photo: PhotoItem) {
      switch photo.kindChip {
      case "MD": self = .markdown
      case "HTML": self = .html
      case "JSON", "JSONL": self = .json
      default: self = .text
      }
    }
  }
  enum Kind: Equatable { case media, document(Page), folder }
  enum Chip: Equatable { case kind(String), duration(String?) }
  /// The thumbnail, drawn by the card so the chips and the selection ring sit above it.
  var picture: NSImage? { didSet { placeholder = nil; if picture !== oldValue { needsDisplay = true } } }
  /// The symbol shown where there is no thumbnail. It is made each time it is drawn, so it takes the faint colour of
  /// the palette's active form; a stored tinted image would keep the colour it was made with.
  var placeholder: String? { didSet { if placeholder != oldValue { needsDisplay = true } } }
  let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  var onActivate: (() -> Void)?
  var onToggle: (() -> Void)?
  var kind = Kind.media { didSet { if kind != oldValue { needsDisplay = true } } }
  var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
  var favorite = false { didSet { if favorite != oldValue { needsDisplay = true } } }
  /// A dot after the name: the file changed since it was last opened.
  var changed = false { didSet { if changed != oldValue { needsDisplay = true } } }
  var chip: Chip? { didSet { if chip != oldValue { needsDisplay = true } } }
  /// The trailing chip: `{ }` for a file with sidecars, Companion for a sidecar listed on its own.
  var marker: String? { didSet { if marker != oldValue { needsDisplay = true } } }
  var selecting = false { didSet { if selecting != oldValue { needsDisplay = true } } }
  var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected) } }
  var active = false { didSet { if oldValue != active { needsDisplay = true } } }
  override var isFlipped: Bool { true }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    check.target = self; check.action = #selector(toggleChecked)
    check.setAccessibilityLabel("Select item")
    addSubview(check); check.setAccessibilityElement(false)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }
  @objc private func toggleChecked() { onToggle?() }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func accessibilityPerformPress() -> Bool {
    guard let onActivate else { return false }
    onActivate()
    return true
  }
  private var well: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - ContactSheetMetrics.captionHeight)) }
  /// Everything inside the well scales with the tile from the design's 180-point tile.
  private var scale: CGFloat { max(0.55, well.width / 180) }
  override func layout() {
    super.layout()
    check.frame = NSRect(x: 8, y: 8, width: 16, height: 16)
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    let wellPath = NSBezierPath(roundedRect: well, xRadius: 8, yRadius: 8)
    FrameColors.stage.setFill()
    wellPath.fill()
    // The checkbox belongs to Select mode; otherwise the ring alone marks a selected tile.
    check.isHidden = !selecting || kind == .folder
    check.isEnabled = selecting
    check.state = selected ? .on : .off
    NSGraphicsContext.saveGraphicsState()
    wellPath.addClip()
    switch kind {
    case .media: drawPicture()
    case .document(let page): drawPage(page)
    case .folder: drawFolder()
    }
    NSGraphicsContext.restoreGraphicsState()
    switch chip {
    case .kind(let text): drawChip(text, play: false, trailing: false)
    case .duration(let text): drawChip(text ?? "", play: true, trailing: false)
    case nil: break
    }
    if let marker { drawChip(marker, play: false, trailing: true) }
    if selected {
      NSColor.selectedContentBackgroundColor.setStroke()
      let ring = NSBezierPath(roundedRect: well.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
      ring.lineWidth = 3
      ring.stroke()
    }
    drawCaption()
  }

  private func drawCaption() {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    let color = active ? NSColor.white : selected ? FrameColors.ink : FrameColors.muted
    let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color,
                                                              .paragraphStyle: paragraph])
    let badgeWidth: CGFloat = (favorite ? 16 : 0) + (changed ? 12 : 0)
    let top = well.maxY + 6
    let textWidth = min(ceil(text.size().width), max(0, bounds.width - badgeWidth - (active ? 12 : 0)))
    // The file on show gets an accent pill behind its name, so it stays distinct inside a multiple selection.
    if active {
      NSColor.selectedContentBackgroundColor.setFill()
      NSBezierPath(roundedRect: NSRect(x: 0, y: top - 1, width: textWidth + badgeWidth + 12, height: 18), xRadius: 5, yRadius: 5).fill()
    }
    let x: CGFloat = active ? 6 : 0
    text.draw(with: NSRect(x: x, y: top + 1, width: textWidth, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    if favorite, let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [active ? .white : FrameColors.amber]))) {
      let size = pin.size
      pin.draw(in: NSRect(x: x + textWidth + 4, y: top + (16 - size.height) / 2, width: size.width, height: size.height))
    }
    if changed {
      (active ? NSColor.white : NSColor.controlAccentColor).setFill()
      NSBezierPath(ovalIn: NSRect(x: x + textWidth + (favorite ? 20 : 5), y: top + 5, width: 6, height: 6)).fill()
    }
  }

  private func drawChip(_ text: String, play: Bool, trailing: Bool) {
    let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: FrameColors.paper, .kern: 0.3])
    let glyph: CGFloat = play ? (text.isEmpty ? 8 : 11) : 0
    let width = ceil(label.size().width) + 10 + glyph
    let rect = NSRect(x: trailing ? well.maxX - 6 - width : well.minX + 6, y: well.maxY - 6 - 16, width: width, height: 16)
    FrameColors.ink.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    if play {
      let triangle = NSBezierPath()
      triangle.move(to: NSPoint(x: rect.minX + 5.5, y: rect.midY - 3.5))
      triangle.line(to: NSPoint(x: rect.minX + 5.5, y: rect.midY + 3.5))
      triangle.line(to: NSPoint(x: rect.minX + 11, y: rect.midY))
      triangle.close()
      FrameColors.paper.setFill()
      triangle.fill()
    }
    label.draw(at: NSPoint(x: rect.minX + 5 + glyph, y: rect.minY + (16 - label.size().height) / 2))
  }

  private var placeholderImage: NSImage? {
    placeholder.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Preview unavailable") }?
      .withSymbolConfiguration(.init(pointSize: 28, weight: .light).applying(.init(paletteColors: [FrameColors.faint])))
  }

  private func drawPicture() {
    guard let picture = picture ?? placeholderImage, picture.size.width > 0, picture.size.height > 0 else { return }
    let room = well.insetBy(dx: 8, dy: 8)
    let fit = min(room.width / picture.size.width, room.height / picture.size.height)
    let size = NSSize(width: (picture.size.width * fit).rounded(), height: (picture.size.height * fit).rounded())
    let rect = NSRect(x: (room.midX - size.width / 2).rounded(), y: (room.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
    picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawFolder() {
    let size = (66 * scale).rounded()
    guard let symbol = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?
      .withSymbolConfiguration(.init(pointSize: size, weight: .ultraLight).applying(.init(paletteColors: [FrameColors.faint]))) else { return }
    let ratio = symbol.size.width / max(1, symbol.size.height)
    let rect = NSRect(x: well.midX - size / 2, y: well.midY - size / ratio / 2, width: size, height: size / ratio)
    symbol.draw(in: rect)
  }

  private func drawPage(_ page: Page) {
    let s = scale
    let width = (92 * s).rounded()
    let rect = NSRect(x: (well.midX - width / 2).rounded(), y: well.minY + (12 * s).rounded(), width: width, height: well.maxY - (12 * s).rounded())
    let path = NSBezierPath(roundedRect: rect, xRadius: 4 * s, yRadius: 4 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    FrameColors.card.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    var y = rect.minY + 12 * s
    let left = rect.minX + 10 * s
    let full = rect.width - 20 * s
    func bar(_ fraction: CGFloat, height: CGFloat, color: NSColor, indent: CGFloat = 0) {
      color.setFill()
      NSBezierPath(roundedRect: NSRect(x: left + indent * s, y: y, width: full * fraction - indent * s, height: height * s),
                   xRadius: 1.5 * s, yRadius: 1.5 * s).fill()
      y += (height + 6) * s
    }
    let title = FrameColors.ink.withAlphaComponent(0.85)
    let line = FrameColors.faint.withAlphaComponent(0.7)
    switch page {
    case .markdown:
      bar(0.62, height: 6, color: title)
      for fraction in [1, 0.68, 1, 0.68] as [CGFloat] { bar(fraction, height: 3, color: line) }
    case .json:
      bar(0.68, height: 3, color: line)
      bar(1, height: 3, color: line, indent: 10)
      bar(0.68, height: 3, color: line, indent: 10)
      bar(1, height: 3, color: line, indent: 10)
      bar(0.68, height: 3, color: line)
    case .html:
      NSColor(srgbRed: 0x1f / 255, green: 0x3a / 255, blue: 0x5f / 255, alpha: 1).setFill()
      let header = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 22 * s)
      NSBezierPath(roundedRect: header, xRadius: 4 * s, yRadius: 4 * s).fill()
      NSBezierPath(rect: NSRect(x: header.minX, y: header.midY, width: header.width, height: header.height / 2)).fill()
      y = header.maxY + 8 * s
      bar(1, height: 3, color: line)
      bar(0.68, height: 3, color: line)
    case .text:
      for fraction in [1, 1, 0.68, 1, 0.68] as [CGFloat] { bar(fraction, height: 3, color: line) }
    }
  }
}
