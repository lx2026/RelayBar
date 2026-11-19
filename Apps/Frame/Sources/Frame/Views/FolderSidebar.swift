import AppKit
import FrameKit
import SwiftUI

/// The left column: the Files/Icons switch beside the window controls, search, the tree and the filters.
struct LibraryColumn: View {
  @ObservedObject var store: LibraryStore
  private var hasLibrary: Bool { store.activeRootID != nil && !store.rootUnavailable }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Color.clear.frame(width: FrameMetrics.windowControlsWidth - FrameMetrics.inset + 6)
        ModeSwitch(store: store)
        Spacer(minLength: 6)
        SidebarButton(store: store)
      }
      .padding(.leading, FrameMetrics.inset).padding(.trailing, 10)
      .frame(height: FrameMetrics.topRowHeight)
      .background(WindowDragArea())
      if hasLibrary {
        if store.isSearchAvailable { SearchBar(store: store).padding(.horizontal, 8).padding(.bottom, 6) }
        FileTree(store: store).disabled(store.isFileOperation)
        LibraryFooter(store: store)
      } else {
        Spacer(minLength: 0)
      }
    }
    .background(FramePalette.panel)
  }
}

private struct SearchBar: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    HStack(spacing: 4) {
      PromptSearchField(store: store)
      if let matches = store.searchMatchCount {
        Text("\(matches) of \(store.folderFileCount)")
          .font(.system(size: 11).monospacedDigit()).foregroundStyle(FramePalette.muted).lineLimit(1).fixedSize()
          .padding(.trailing, 5)
      }
    }
    .padding(.leading, 3).padding(.trailing, 2)
    .frame(height: 28)
    .background(FramePalette.fill, in: RoundedRectangle(cornerRadius: FrameMetrics.radius, style: .continuous))
    .disabled(store.isFileOperation)
  }
}

/// The kind filter, favourites only and Archive.
private struct LibraryFooter: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    let favoritesOnly = store.filter == .favorites
    let archive = store.filter == .archive
    HStack(spacing: 4) {
      KindFilterMenu(store: store)
      Spacer(minLength: 0)
      Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
        .buttonStyle(IconButtonStyle())
        .disabled(!store.canRefresh)
        .accessibilityLabel("Refresh folder")
        .help("Refresh folder (⌘R)")
      Button { store.setFilter(favoritesOnly ? .all : .favorites) } label: {
        Image(systemName: favoritesOnly ? "heart.fill" : "heart")
      }
      .buttonStyle(IconButtonStyle(tint: favoritesOnly ? FramePalette.amber : FramePalette.muted, isOn: favoritesOnly))
      .disabled(archive)
      .accessibilityLabel("Show favorites only").accessibilityAddTraits(favoritesOnly ? .isSelected : [])
      .help("Show favorites only")
      Button { store.setFilter(archive ? .all : .archive) } label: { Image(systemName: "archivebox") }
        .buttonStyle(IconButtonStyle(tint: archive ? FramePalette.ink : FramePalette.muted, isOn: archive))
        .accessibilityLabel("Archive").accessibilityAddTraits(archive ? .isSelected : [])
        .help(archive ? "Leave Archive" : "Show Archive")
    }
    .padding(.horizontal, 8)
    .frame(height: FrameMetrics.footerHeight)
    .overlay(alignment: .top) { Hairline() }
    .disabled(store.isFileOperation)
  }
}

/// Every filter on the files a folder shows, apart from search and Archive.
struct KindFilterMenu: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    Menu {
      Picker("Kind", selection: Binding(get: { store.fileTypeFilter }, set: store.setFileTypeFilter)) {
        ForEach(FileTypeFilter.allCases) { Text($0.kindTitle).tag($0) }
      }.pickerStyle(.inline).labelsHidden()
      Divider()
      Toggle("Hide Favorites", isOn: Binding(get: { store.filter == .notFavorited },
        set: { store.setFilter($0 ? .notFavorited : .all) }))
        .disabled(store.filter == .archive)
      Divider()
      Toggle("Show Sidecar Files", isOn: Binding(get: { store.showsSidecarFiles }, set: store.setShowsSidecarFiles))
      Divider()
      Button("Clear Filters", action: store.clearFileFilters)
        .disabled(!store.hasFileFilters && store.searchQuery.isEmpty)
    } label: {
      HStack(spacing: 4) {
        Text(store.fileTypeFilter.kindTitle + (store.filter == .notFavorited ? " · Hide favorites" : ""))
          .font(.system(size: 12)).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .foregroundStyle(store.hasFileFilters ? FramePalette.ink : FramePalette.muted)
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .padding(.leading, 8).padding(.trailing, 6).frame(height: 24)
    .accessibilityLabel("File filter: \(store.fileFilterLabel)")
    .help("Filter by file type and favorites")
    .disabled(store.isFileOperation)
  }
}

/// The library's folders and files in one outline.
private struct FileTree: NSViewRepresentable {
  @ObservedObject var store: LibraryStore
  func makeCoordinator() -> Coordinator { Coordinator(store) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = OverlayScrollView(), outline = FileOutline()
    outline.identifier = NSUserInterfaceItemIdentifier("FrameFileTree")
    outline.headerView = nil
    outline.rowHeight = TreeMetrics.rowHeight
    outline.indentationPerLevel = TreeMetrics.indent
    outline.intercellSpacing = .zero
    outline.backgroundColor = .clear
    outline.style = .plain
    outline.selectionHighlightStyle = .regular
    outline.focusRingType = .none
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    column.resizingMask = .autoresizingMask; outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    outline.dataSource = context.coordinator; outline.delegate = context.coordinator
    outline.onDelete = { [weak coordinator = context.coordinator] in coordinator?.deleteCurrent() }
    scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
    context.coordinator.outline = outline; context.coordinator.update(store)
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(store) }

  @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Node {
      let path: String
      var name: String
      var file: PhotoItem?
      var children: [Node] = []
      var isRoot = false
      init(path: String, name: String) { self.path = path; self.name = name }
    }
    var store: LibraryStore
    weak var outline: FileOutline?
    private var nodes: [String: Node] = [:]
    private var root: Node?
    private var signature = ""
    private var expansion: Set<String> = []
    private var decoration = ""
    private var updating = false
    init(_ store: LibraryStore) { self.store = store }
    func update(_ store: LibraryStore) {
      self.store = store
      guard let outline else { return }
      let key = "\(store.activeRootID?.uuidString ?? "")|\(store.remoteFolders?.rootPath ?? "")|\(store.localFolders?.revision ?? store.remoteFolders?.revision ?? 0)|\(store.showsSidecarFiles)"
      updating = true
      defer { updating = false }
      if key != signature {
      var retained: Set<String> = []
      func node(_ path: String, _ name: String, file: PhotoItem? = nil) -> Node {
        let key = (file == nil ? "d:" : "f:") + path
        let value = nodes[key] ?? Node(path: path, name: name)
        nodes[key] = value; value.file = file; value.name = name; value.isRoot = false; retained.insert(key)
        return value
      }
      func build(_ path: String, _ name: String, depth: Int) -> Node {
        let value = node(path, name)
        guard depth < 64 else { return value }
        let children: [(String, String)]
        if let tree = store.remoteFolders {
          children = (tree.nodes[path]?.children ?? []).map { ($0, ($0 as NSString).lastPathComponent) }
        } else {
          children = (store.localFolders?.results[path]?.rootFolder.children ?? []).map { ($0.relativePath, $0.name) }
        }
        value.children = children.map { build($0.0, $0.1, depth: depth + 1) }
          + store.treeFiles(in: path).map { node($0.relativePath, $0.name, file: $0) }
        return value
      }
      let rootPath = store.remoteFolders?.rootPath ?? ""
      root = build(rootPath, store.isRemote ? (rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent) : store.rootName, depth: 0)
      root?.isRoot = true
      nodes = nodes.filter { retained.contains($0.key) }
        let y = outline.enclosingScrollView?.contentView.bounds.origin ?? .zero
        signature = key; outline.reloadData()
        expansion = []
        outline.enclosingScrollView?.contentView.scroll(to: y)
      }
      let expanded = store.remoteFolders?.expanded ?? store.localFolders?.expanded ?? [""]
      if expanded != expansion {
        for path in expanded.sorted(by: { $0.count < $1.count }) {
          if let value = nodes["d:" + path] { outline.expandItem(value) }
        }
        expansion = expanded
      }
      // Favourite hearts, the root row's actions and its progress are drawn by the cells; refresh them in place.
      let state = "\(store.favorites.hashValue)|\(store.openedTimes.hashValue)|\(store.folderBaselines.hashValue)|\(store.isScanning)|\(store.isFileOperation)|\(store.canRefresh)|\(store.remotePath)"
      if state != decoration {
        decoration = state
        let rows = outline.rows(in: outline.visibleRect)
        if rows.length > 0 {
          outline.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)), columnIndexes: [0])
        }
      }
      // Icons mode shows a folder, so the tree marks the folder; Files mode marks the file on show.
      let showsFolder = store.folderIsSelected || store.viewMode == .contactSheet || store.selectedPhoto == nil
      let selectedNode = store.filter == .archive ? nil : showsFolder ? nodes["d:" + store.selectedFolderPath]
        : store.selectedPhoto.flatMap { nodes["f:" + $0.relativePath] }
      if let item = selectedNode {
        let row = outline.row(forItem: item)
        if row >= 0, outline.selectedRow != row {
          outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          outline.scrollRowToVisible(row)
        }
      } else if store.filter == .archive, outline.selectedRow >= 0 {
        outline.deselectAll(nil)
      }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? (root == nil ? 0 : 1) }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? root! }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.file == nil }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
      (outlineView.makeView(withIdentifier: TreeRowView.identifier, owner: self) as? TreeRowView) ?? TreeRowView()
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
      guard let node = item as? Node else { return nil }
      let cell = (outlineView.makeView(withIdentifier: TreeCell.identifier, owner: self) as? TreeCell) ?? TreeCell()
      let error = store.remoteFolders?.nodes[node.path]?.error ?? store.localFolders?.errors[node.path]
      let symbol = error != nil ? "exclamationmark.circle" : node.file?.format.symbol ?? "folder"
      cell.configure(name: node.name, symbol: symbol, symbolDescription: error != nil ? "Retry" : node.file?.format.rawValue ?? "Folder",
                     isRoot: node.isRoot, favorite: node.file.map(store.isFavorite) ?? false,
                     changed: node.file.map(store.isChanged) ?? false)
      if node.isRoot {
        cell.showActions(menu: libraryMenu(), scanning: store.isScanning)
      }
      let companion = node.file.flatMap(store.companionDescription)
      cell.toolTip = error ?? (node.path + (companion.map { "\n" + $0 } ?? ""))
      cell.setAccessibilityLabel(node.name + (companion.map { ", " + $0 } ?? ""))
      return cell
    }
    /// The library actions that used to sit in the toolbar. The main menu keeps their shortcuts.
    private func libraryMenu() -> NSMenu {
      let menu = NSMenu()
      menu.autoenablesItems = false
      func add(_ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command, enabled: Bool, action: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        menu.addItem(item)
      }
      add("Open…", key: "o", enabled: !store.isFileOperation) { [weak self] in self?.store.presentOpenChooser() }
      if store.isRemote {
        add("Parent Folder", key: String(utf16CodeUnits: [unichar(NSUpArrowFunctionKey)], count: 1), enabled: store.remotePath != "/" && !store.isFileOperation) { [weak self] in
          self?.store.remoteParent()
        }
      }
      add("Refresh", key: "r", enabled: store.canRefresh) { [weak self] in self?.store.refresh() }
      return menu
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let outline, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
      if let file = node.file { store.showFile(file) }
      else { store.selectFolder(node.path) }
    }
    func deleteCurrent() {
      guard let outline, let file = (outline.item(atRow: outline.selectedRow) as? Node)?.file,
            store.selectionID == file.id else { return }
      store.deleteSelected()
    }
    func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, expanded: true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, expanded: false) }
    private func expansion(_ notification: Notification, expanded: Bool) {
      guard !updating, let node = notification.userInfo?["NSObject"] as? Node else { return }
      if store.remoteFolders != nil {
        store.setRemoteFolderExpanded(node.path, expanded)
      } else if let tree = store.localFolders, tree.expanded.contains(node.path) != expanded { tree.toggle(node.path) }
    }
  }
}

/// Row geometry from the design: 26-point rows, 16 points of indent, an 8-point inset on either side.
private enum TreeMetrics {
  static let rowHeight: CGFloat = 26
  static let indent: CGFloat = 16
  static let rowInset: CGFloat = 8
  /// Where the disclosure chevron's 10-point glyph starts at the outermost level.
  static let chevronX: CGFloat = 16
  /// Where the kind icon starts at the outermost level: after the chevron and a 6-point gap.
  static let iconX: CGFloat = 32
}

private final class FileOutline: NSOutlineView {
  var onDelete: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if [51, 117].contains(event.keyCode), modifiers.isEmpty || modifiers == .command { onDelete?(); return }
    super.keyDown(with: event)
  }
  override func frameOfOutlineCell(atRow row: Int) -> NSRect {
    let frame = super.frameOfOutlineCell(atRow: row)
    guard !frame.isEmpty else { return frame }
    let level = CGFloat(level(forRow: row))
    let width = frame.width
    return NSRect(x: TreeMetrics.chevronX + TreeMetrics.indent * level + 5 - width / 2, y: frame.minY,
                  width: width, height: frame.height)
  }
  override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
    let rowRect = rect(ofRow: row)
    let x = TreeMetrics.iconX + TreeMetrics.indent * CGFloat(max(0, level(forRow: row)))
    return NSRect(x: x, y: rowRect.minY, width: max(0, rowRect.maxX - TreeMetrics.rowInset - x), height: rowRect.height)
  }
}

/// The selected row is a rounded accent fill with white text, whether or not the tree has the focus.
private final class TreeRowView: NSTableRowView {
  static let identifier = NSUserInterfaceItemIdentifier("FrameTreeRow")
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isEmphasized: Bool {
    get { true }
    set {}
  }
  override func drawSelection(in dirtyRect: NSRect) {
    NSColor.selectedContentBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: TreeMetrics.rowInset, dy: 0), xRadius: 6, yRadius: 6).fill()
  }
  override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

private final class TreeCell: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("FrameTreeCell")
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let heart = NSImageView()
  private let changedDot = ChangedDot()
  private let actions = LibraryActionsButton()
  private let spinner = NSProgressIndicator()
  private var isRoot = false
  private var isFavorite = false
  private var scanning = false
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier
    label.font = .systemFont(ofSize: 13)
    label.lineBreakMode = .byTruncatingMiddle
    label.cell?.truncatesLastVisibleLine = true
    icon.imageScaling = .scaleProportionallyDown
    icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    heart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favorite")
    heart.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    actions.setAccessibilityLabel("Library actions")
    actions.toolTip = "Open, Refresh"
    for view in [icon, label, heart, changedDot, actions, spinner] as [NSView] { addSubview(view) }
    textField = label
    imageView = icon
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func configure(name: String, symbol: String, symbolDescription: String, isRoot: Bool, favorite: Bool, changed: Bool) {
    label.stringValue = name
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbolDescription)
    self.isRoot = isRoot
    isFavorite = favorite
    label.font = .systemFont(ofSize: 13, weight: isRoot ? .semibold : .regular)
    heart.isHidden = !favorite
    changedDot.isHidden = !changed
    actions.isHidden = true
    scanning = false
    spinner.stopAnimation(nil)
    applyColors()
    needsLayout = true
  }
  func showActions(menu: NSMenu, scanning: Bool) {
    actions.isHidden = false
    actions.menu = menu
    self.scanning = scanning
    if scanning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    needsLayout = true
  }
  override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }
  private func applyColors() {
    let selected = backgroundStyle == .emphasized
    label.textColor = selected ? .white : FrameColors.ink
    icon.contentTintColor = selected ? .white : FrameColors.muted
    heart.contentTintColor = selected ? .white : FrameColors.amber
    changedDot.color = selected ? .white : .controlAccentColor
    actions.contentTintColor = selected ? .white : FrameColors.muted
  }
  override func layout() {
    super.layout()
    let height = bounds.height
    icon.frame = NSRect(x: 0, y: (height - 16) / 2, width: 16, height: 16)
    var trailing = bounds.width - 8
    if !actions.isHidden {
      actions.frame = NSRect(x: trailing - 20, y: (height - 20) / 2, width: 20, height: 20)
      trailing -= 22
      spinner.frame = NSRect(x: trailing - 16, y: (height - 16) / 2, width: 16, height: 16)
      if scanning { trailing -= 18 }
    }
    if !changedDot.isHidden {
      changedDot.frame = NSRect(x: trailing - 8, y: (height - 6) / 2, width: 6, height: 6)
      trailing -= 12
    }
    if !heart.isHidden {
      heart.frame = NSRect(x: trailing - 11, y: (height - 11) / 2, width: 11, height: 11)
      trailing -= 15
    }
    let x: CGFloat = 22
    label.frame = NSRect(x: x, y: (height - 17) / 2, width: max(0, trailing - x), height: 17)
  }
}

/// The 6-point dot on a file changed since it was last opened.
private final class ChangedDot: NSView {
  var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Changed since last opened")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    NSBezierPath(ovalIn: bounds).fill()
  }
}

/// The root row's pull-down. Its shortcuts are shown for reference; the main menu answers them.
private final class LibraryActionsButton: NSButton {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Library actions")
    symbolConfiguration = .init(pointSize: 13, weight: .regular)
    isBordered = false
    imagePosition = .imageOnly
    setButtonType(.momentaryChange)
    target = self
    action = #selector(showMenu)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
  @objc private func showMenu() {
    guard let menu else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
  }
}

/// A menu item that runs a closure, so a menu can be built in place without a target object per item.
final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void
  init(title: String, keyEquivalent: String = "", action handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
    target = self
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @objc private func run() { handler() }
}
