import PreviewSupport
import AppKit
import FrameKit
import SwiftUI

struct ContactSheetWorkspace: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    if store.visiblePhotos.isEmpty {
      ContactSheetBrowser(store: store)
    } else if store.selectedPhoto?.format.isDocument == true {
      PersistentSplitView(name: "Frame.ContactSheet.Width", vertical: true, minimumFirst: 330, minimumSecond: 320,
        first: ContactSheetBrowser(store: store), second: ContactSheetPreview(store: store))
    } else {
    PersistentSplitView(name: "Frame.ContactSheet.Width", vertical: true,
      minimumFirst: 330, minimumSecond: 320,
      first: ContactSheetBrowser(store: store),
      second: PersistentSplitView(name: "Frame.ContactSheet.PreviewHeight", vertical: false,
        minimumFirst: 180, minimumSecond: 170,
        first: ContactSheetPreview(store: store), second: ContactSheetMetadata(store: store)))
    }
  }
}

private struct ContactSheetBrowser: View {
  @ObservedObject var store: LibraryStore
  @State private var showsScanDetails = false
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(store.hasFileFilters ? "\(store.visiblePhotos.count) of \(store.folderFileCount) files" : "\(store.visiblePhotos.count) \(store.visiblePhotos.count == 1 ? "file" : "files")")
          .font(.system(size: 12, weight: .medium)).lineLimit(1)
        Spacer(minLength: 0)
        FileFilterMenu(store: store)
        HStack(spacing: 6) {
          Slider(value: Binding(get: { store.thumbnailWidth }, set: { value in Task { await store.setThumbnailWidth(value) } }),
            in: ContactSheetMetrics.thumbnailRange, step: 10)
            .frame(width: 82).accessibilityLabel("Thumbnail size")
            .accessibilityValue("\(Int(store.thumbnailWidth)) points")
        }
      }.padding(.horizontal, 16).frame(height: 44).background(FramePalette.paper)
        .disabled(store.isFileOperation)
      if store.filter != .archive {
        HStack(spacing: 10) {
          Toggle("Subfolders", isOn: Binding(get: { store.includesSubfolders }, set: { value in Task { await store.setIncludesSubfolders(value) } }))
            .toggleStyle(.checkbox).disabled(store.isFileOperation)
          Spacer(minLength: 0)
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
                }.font(.system(size: 12)).padding(18).frame(width: 320)
              }
          }
        }.font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 12)
      }
      Divider()
      if store.visiblePhotos.isEmpty {
        EmptyFilesView(store: store)
      } else {
        NativeContactSheet(store: store)
      }
    }
  }
}

struct FileFilterMenu: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    Menu {
      Picker("File type", selection: Binding(get: { store.fileTypeFilter }, set: store.setFileTypeFilter)) {
        ForEach(FileTypeFilter.allCases) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.inline)
      if store.filter != .archive {
        Divider()
        Picker("Favorites", selection: Binding(get: { store.filter }, set: store.setFilter)) {
          Text("Any favorite status").tag(PhotoFilter.all)
          Text("Favorites only").tag(PhotoFilter.favorites)
          Text("Hide favorites").tag(PhotoFilter.notFavorited)
        }.pickerStyle(.inline)
      }
      if store.hasFileFilters {
        Divider()
        Button("Clear filters", action: store.clearFileFilters)
      }
    } label: {
      Label(store.fileFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
        .lineLimit(1)
    }
    .accessibilityLabel("File filter: \(store.fileFilterLabel)")
    .frame(maxWidth: 220)
    .help("Filter by file type and favorites")
    .disabled(store.isFileOperation)
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

private struct ContactSheetPreview: View {
  @ObservedObject var store: LibraryStore
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        if let photo = store.selectedPhoto, !store.selectionMissing {
          HStack(spacing: 8) {
            Text(photo.name).font(.system(size: 12, weight: .medium))
              .lineLimit(1).truncationMode(.middle).help(photo.relativePath)
            Spacer(minLength: 0)
            if photo.remote != nil && photo.format.isImage {
              Button("Original",
                action: store.loadOriginal).buttonStyle(.plain).font(.system(size: 11))
                .disabled(store.isLoadingOriginal || store.originalPreview != nil)
                .help("Download full-resolution original")
            }
            Button { store.inspect(photo) } label: {
              Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.buttonStyle(.plain).font(.system(size: 11)).disabled(!store.canInspect)
              .help("Open viewer (Return)").accessibilityLabel("Open viewer")
          }.padding(.horizontal, 14).frame(height: 42).background(FramePalette.paper)
          Group {
            if photo.format.isDocument {
              DocumentPreview(photo: photo, store: store)
            } else if photo.remote != nil && photo.format.isVideo {
              VideoStage(photo: photo, playback: store.playback)
            } else {
              LoadedImageView(photo: store.originalPreview ?? photo, maxPixelSize: ContactSheetMetrics.previewPixels(
                width: geometry.size.width - 24, height: geometry.size.height - 66, scale: displayScale))
                .padding(12)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          VStack(spacing: 10) {
            Image(systemName: "photo").font(.system(size: 24, weight: .light))
            if store.selectionMissing { Text("File missing")
              .font(.system(size: 12)).multilineTextAlignment(.center)
            }
          }.foregroundStyle(FramePalette.muted).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }.frame(width: geometry.size.width, height: geometry.size.height).background(FramePalette.stage)
    }
  }
}

private struct ContactSheetMetadata: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    Group {
      if let photo = store.selectedPhoto, !store.selectionMissing {
        MetadataPanel(photo: photo, store: store)
      } else {
        Color.clear
      }
    }.background(FramePalette.paper)
  }
}

struct SelectionActionsBar: View {
  @ObservedObject var store: LibraryStore
  private var count: Int { store.actionPhotos.count }
  var body: some View {
    HStack(spacing: 14) {
      if store.isFileOperation {
        ProgressView(value: Double(store.operationProgress), total: Double(max(1, store.operationTotal))).frame(width: 100)
        Text("\(store.operationTitle) \(store.operationProgress) of \(store.operationTotal)")
        if store.operationTitle != "Restoring from Trash" && !(store.isRemote && store.operationTitle == "Deleting") {
          Button("Cancel", action: store.cancelFileOperation).buttonStyle(.bordered)
        }
      } else {
        if store.isSelecting || count != 1 { Text("\(count) selected").fontWeight(.medium).fixedSize() }
        Spacer(minLength: 0)
        Button {
          store.toggleFavorite()
        } label: {
          Label("Favorite", systemImage: store.allActionPhotosFavorite ? "heart.fill" : "heart")
        }.disabled(!store.canFavorite).help("Favorite and next (F)")
        Button(store.isExporting ? "Exporting…" : "Export…", action: store.exportSelected)
          .disabled(!store.canExport)
          .help(store.exportHelp)
        Group {
          Button(store.filter == .archive ? "Restore" : "Archive", action: store.archiveSelected)
            .disabled(!store.canArchive).help(store.groupedActionHelp ?? "Move selected groups to Archive")
          Button(store.deleteTitle + (store.isSelecting || count > 1 ? " \(count)" : ""), action: store.deleteSelected)
            .disabled(!store.canDelete).help(store.deleteHelp)
        }
      }
    }.buttonStyle(.bordered).font(.system(size: 11)).padding(.horizontal, 16)
      .frame(height: 50).background(FramePalette.paper)
  }
}

/// Reusable native cells keep selection, marquee, scrolling and range anchors in AppKit.
struct NativeContactSheet: NSViewRepresentable {
  @ObservedObject var store: LibraryStore
  func makeCoordinator() -> Coordinator { Coordinator(store: store) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let grid = MediaCollectionView()
    grid.isSelectable = true
    grid.allowsMultipleSelection = true
    grid.allowsEmptySelection = true
    grid.backgroundColors = [FrameColors.paper]
    let layout = NSCollectionViewFlowLayout()
    layout.itemSize = NSSize(width: store.thumbnailWidth, height: store.thumbnailWidth + 24)
    layout.minimumInteritemSpacing = 12
    layout.minimumLineSpacing = 16
    layout.sectionInset = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
    grid.collectionViewLayout = layout
    grid.register(MediaCell.self, forItemWithIdentifier: MediaCell.identifier)
    grid.delegate = context.coordinator
    context.coordinator.grid = grid
    context.coordinator.installDataSource(grid)
    grid.onPreview = { [weak coordinator = context.coordinator] index in coordinator?.preview(index) }
    grid.onInspect = { [weak coordinator = context.coordinator] in coordinator?.inspect() }
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
    coordinator.synchronizing = true
    let scope = store.gridScopeKey
    if scope != coordinator.scopeKey {
      if let old = coordinator.scopeKey { store.gridScrollPositions[old] = view.contentView.bounds.origin.y }
      coordinator.scopeKey = scope
      coordinator.restoreScroll = true
    }
    if photos != coordinator.photos {
      coordinator.apply(photos, preservingViewport: !coordinator.restoreScroll)
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
    var byID: [String: PhotoItem] = [:]
    var dataSource: NSCollectionViewDiffableDataSource<Int, String>!
    weak var grid: MediaCollectionView?
    var synchronizing = false
    var applyingSnapshot = false
    var snapshotGeneration = 0
    var lastPreviewID: String?
    var scopeKey: String?
    var restoreScroll = true
    init(store: LibraryStore) { self.store = store }
    func installDataSource(_ grid: MediaCollectionView) {
      dataSource = NSCollectionViewDiffableDataSource<Int, String>(collectionView: grid) { [weak self, weak grid] collection, path, id in
        guard let self, let grid, let photo = byID[id] else { return nil }
        let item = collection.makeItem(withIdentifier: MediaCell.identifier, for: path) as! MediaCell
        item.configure(photo, favorite: store.isFavorite(photo), active: id == store.selectionID, selecting: store.isSelecting, pixelSize: grid.thumbnailPixels, previews: store.previews, companion: store.companionDescription(photo))
        item.onActivate = { [weak self, weak grid] in
          guard let index = self?.photos.firstIndex(where: { $0.id == id }) else { return }
          grid?.activateItem(at: index)
        }
        item.onToggle = { [weak self] in
          guard let self, let photo = byID[id] else { return }
          store.select(photo); store.toggleCurrentSelection()
        }
        return item
      }
    }
    func apply(_ next: [PhotoItem], preservingViewport: Bool) {
      guard let grid, let scroll = grid.enclosingScrollView else { return }
      let oldIDs = photos.map(\.id), newIDs = next.map(\.id)
      let top = grid.indexPathsForVisibleItems().min { $0.item < $1.item }
      let oldTop = top.flatMap { photos.indices.contains($0.item) ? photos[$0.item].id : nil }
      let offset = top.flatMap { grid.collectionViewLayout?.layoutAttributesForItem(at: $0) }
        .map { scroll.contentView.bounds.minY - $0.frame.minY } ?? 0
      photos = next
      byID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
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
            let y = min(max(0, attributes.frame.minY + offset), max(0, grid.bounds.height - scroll.contentSize.height))
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
      let indexes = Set(photos.enumerated().compactMap { store.batchSelection.ids.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil })
      if grid.selectionIndexPaths != indexes { grid.selectionIndexPaths = indexes }
      grid.currentIndex = photos.firstIndex { $0.id == store.selectionID }
      if lastPreviewID != store.selectionID {
        lastPreviewID = store.selectionID
        if let index = grid.currentIndex,
           let attributes = grid.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
          grid.scrollToVisible(attributes.frame)
        }
      }
      updateVisibleThumbnails()
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
      (item as? MediaCell)?.cancelLoad()
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
      guard let id = dataSource.itemIdentifier(for: indexPath), let photo = byID[id] else { return }
      (item as? MediaCell)?.configure(photo, favorite: store.isFavorite(photo), active: photo.id == store.selectionID, selecting: store.isSelecting, pixelSize: grid?.thumbnailPixels ?? 384, previews: store.previews, companion: store.companionDescription(photo))
    }
    func updateVisibleThumbnails() {
      guard !applyingSnapshot, let grid else { return }
      for path in grid.indexPathsForVisibleItems() where photos.indices.contains(path.item) {
        let photo = photos[path.item]
        (grid.item(at: path) as? MediaCell)?.configure(photo, favorite: store.isFavorite(photo), active: photo.id == store.selectionID, selecting: store.isSelecting, pixelSize: grid.thumbnailPixels, previews: store.previews, companion: store.companionDescription(photo))
      }
    }
    func syncSelection() {
      guard !synchronizing, !applyingSnapshot, let grid, !store.isFileOperation else { return }
      let ids = Set(grid.selectionIndexPaths.compactMap { photos.indices.contains($0.item) ? photos[$0.item].id : nil })
      let current = grid.currentIndex.flatMap { photos.indices.contains($0) ? photos[$0].id : nil }
      store.updateGridSelection(ids, currentID: current)
    }
    func preview(_ index: Int) {
      guard photos.indices.contains(index), let grid else { return }
      grid.currentIndex = index
      syncSelection()
    }
    func inspect() {
      guard let photo = store.selectedPhoto else { return }
      store.inspect(photo)
    }
    func clear() { grid?.deselectAll(nil); syncSelection() }
  }
}

@MainActor final class MediaCollectionView: NSCollectionView {
  var onPreview: ((Int) -> Void)?
  var onInspect: (() -> Void)?
  var onClear: (() -> Void)?
  var onEscape: (() -> Void)?
  var onFavorite: (() -> Void)?
  var onLayoutChange: (() -> Void)?
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
    if !previewOnly {
      if extending {
        guard let bounds = rangeAnchor.range(to: index, current: currentIndex, count: numberOfItems(inSection: 0)) else { return }
        let range = Set(bounds.map { IndexPath(item: $0, section: 0) })
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
    if event.keyCode == 53 && flags.isEmpty { onEscape?(); return }
    if event.keyCode == 36 && flags.isEmpty { onInspect?(); return }
    if event.charactersIgnoringModifiers?.lowercased() == "g", flags.isEmpty { onInspect?(); return }
    if event.charactersIgnoringModifiers?.lowercased() == "f", flags.isEmpty { onFavorite?(); return }
    if event.charactersIgnoringModifiers?.lowercased() == "a", flags == [.command, .shift] { onClear?(); return }
    if event.charactersIgnoringModifiers?.lowercased() == "a", flags == .command {
      selectAll(nil)
      if numberOfItems(inSection: 0) > 0 { onPreview?(currentIndex ?? 0) }
      return
    }
    if event.keyCode == 49 { return } // Browse is a static preview; AVKit owns playback in Inspect.
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
  func setFavorite(_ value: Bool) { card.favorite.stringValue = value ? "♥" : "" }
  func configure(_ photo: PhotoItem, favorite: Bool, active: Bool, selecting: Bool, pixelSize: Int, previews: FrameComposition, companion: String?) {
    let settingsID = previews.settingsID(for: photo)
    setFavorite(favorite)
    card.selecting = selecting
    card.active = active
    card.name.stringValue = photo.name
    card.setAccessibilityLabel(photo.name + (companion.map { ", " + $0 } ?? "") + (photo.companions.isEmpty ? "" : ", \(photo.companions.count) companion files") + (active ? ", active preview" : ""))
    card.check.setAccessibilityLabel("Select \(photo.name)")
    card.toolTip = photo.exportMembers.map(\.relativePath).joined(separator: "\n")
    if let companion { card.toolTip = (card.toolTip ?? "") + "\n" + companion }
    if contentID != photo.contentID || previewSettingsID != settingsID {
      cancelLoad()
      contentID = photo.contentID
      previewSettingsID = settingsID
      loadedPixels = 0
      card.image.image = nil
      card.duration.stringValue = photo.format.isVideo ? "▶" : ""
    }
    if photo.format.isDocument {
      cancelLoad()
      card.duration.stringValue = photo.companionOwnerID == nil ? "" : "Companion"
      card.needsLayout = true
      card.image.image = NSImage(systemSymbolName: photo.format.symbol, accessibilityDescription: photo.format.rawValue)
      return
    }
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
        self.previewSession = nil; self.loadedPixels = 0; self.requestedPixels = 0; self.card.image.image = nil
      }
      loadedPixels = session == nil ? 0 : pixelSize
      card.image.image = session?.content.image.map { NSImage(cgImage: $0, size: .zero) }
        ?? NSImage(systemSymbolName: photo.format.isVideo ? "play.slash" : "photo", accessibilityDescription: "Preview unavailable")
      if photo.format.isVideo {
        let info = try? await previews.media.videoInfo(photo)
        guard !Task.isCancelled, contentID == photo.contentID else { return }
        card.duration.stringValue = "▶ \(info?.durationLabel ?? "")"
        card.needsLayout = true
      }
    }
  }
}

@MainActor private final class ThumbnailCard: NSView {
  let image = NSImageView()
  let name = NSTextField(labelWithString: "")
  let duration = NSTextField(labelWithString: "")
  let favorite = NSTextField(labelWithString: "")
  let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
  var onActivate: (() -> Void)?
  var onToggle: (() -> Void)?
  var selecting = false { didSet { needsDisplay = true } }
  var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected) } }
  var active = false { didSet { if oldValue != active { needsDisplay = true } } }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    image.imageScaling = .scaleProportionallyUpOrDown
    name.font = .systemFont(ofSize: 11)
    name.lineBreakMode = .byTruncatingMiddle
    name.maximumNumberOfLines = 1
    duration.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    duration.textColor = .white
    duration.backgroundColor = NSColor.black.withAlphaComponent(0.8)
    duration.drawsBackground = true
    favorite.font = .systemFont(ofSize: 12)
    favorite.textColor = FrameColors.amber
    check.target = self; check.action = #selector(toggleChecked)
    check.setAccessibilityLabel("Select item")
    for child in [image, name, duration, favorite, check] { addSubview(child); child.setAccessibilityElement(false) }
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
  override func layout() {
    super.layout()
    image.frame = NSRect(x: 5, y: 25, width: bounds.width - 10, height: bounds.height - 30)
    name.frame = NSRect(x: 7, y: 3, width: bounds.width - 14, height: 17)
    duration.frame = NSRect(x: 7, y: 28, width: duration.stringValue.isEmpty ? 0 : max(48, duration.intrinsicContentSize.width + 6), height: 16)
    favorite.frame = NSRect(x: bounds.width - 21, y: bounds.height - 22, width: 18, height: 18)
    check.frame = NSRect(x: 7, y: bounds.height - 22, width: 16, height: 16)
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    FrameColors.stage.setFill()
    NSBezierPath(roundedRect: NSRect(x: 1, y: 23, width: bounds.width - 2, height: bounds.height - 24), xRadius: 3, yRadius: 3).fill()
    check.isHidden = !selecting && !selected
    check.isEnabled = selecting
    check.state = selected ? .on : .off
    if active {
      FrameColors.button.setFill()
      NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: bounds.width - 2, height: 22), xRadius: 3, yRadius: 3).fill()
    }
    name.textColor = active ? FrameColors.buttonText : FrameColors.muted
    if selected || active {
      (active ? FrameColors.ink : FrameColors.muted).setStroke()
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
      path.lineWidth = active ? 3 : 1
      path.stroke()
    }
  }
}
