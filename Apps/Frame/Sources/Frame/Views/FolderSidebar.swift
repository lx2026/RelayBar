import AppKit
import FrameKit
import SwiftUI

struct FolderSidebar: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    VStack(spacing: 0) {
      if store.isRemote, store.remoteFolders?.rootPath != "/" {
        Button(action: store.remoteParent) { Label("Parent Folder", systemImage: "arrow.up") }
          .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }
      FileTree(store: store)
      Divider()
      Button { store.setFilter(.archive) } label: {
        Label("Archive", systemImage: "archivebox").frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(.plain).padding(12)
    }.background(FramePalette.panel).disabled(store.isFileOperation)
  }
}

private struct FileTree: NSViewRepresentable {
  @ObservedObject var store: LibraryStore
  func makeCoordinator() -> Coordinator { Coordinator(store) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(), outline = FileOutline()
    outline.identifier = NSUserInterfaceItemIdentifier("FrameFileTree")
    outline.headerView = nil; outline.rowHeight = 28; outline.indentationPerLevel = 14
    outline.backgroundColor = FrameColors.panel; outline.style = .sourceList
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    column.resizingMask = .autoresizingMask; outline.addTableColumn(column); outline.outlineTableColumn = column
    outline.dataSource = context.coordinator; outline.delegate = context.coordinator
    outline.onDelete = { [weak coordinator = context.coordinator] in coordinator?.deleteCurrent() }
    scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
    context.coordinator.outline = outline; context.coordinator.update(store)
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(store) }

  @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
      let path: String
      var name: String
      var file: PhotoItem?
      var children: [Node] = []
      init(path: String, name: String) { self.path = path; self.name = name }
    }
    var store: LibraryStore
    weak var outline: FileOutline?
    private var nodes: [String: Node] = [:]
    private var root: Node?
    private var signature = ""
    private var expansion: Set<String> = []
    private var updating = false
    init(_ store: LibraryStore) { self.store = store }
    func update(_ store: LibraryStore) {
      self.store = store
      guard let outline else { return }
      let key = "\(store.activeRootID?.uuidString ?? "")|\(store.remoteFolders?.rootPath ?? "")|\(store.localFolders?.revision ?? store.remoteFolders?.revision ?? 0)"
      updating = true
      defer { updating = false }
      if key != signature {
      var retained: Set<String> = []
      func node(_ path: String, _ name: String, file: PhotoItem? = nil) -> Node {
        let key = (file == nil ? "d:" : "f:") + path
        let value = nodes[key] ?? Node(path: path, name: name)
        nodes[key] = value; value.file = file; value.name = name; retained.insert(key)
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
          + store.files(in: path).map { node($0.relativePath, $0.name, file: $0) }
        return value
      }
      let rootPath = store.remoteFolders?.rootPath ?? ""
      root = build(rootPath, store.isRemote ? (rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent) : store.rootName, depth: 0)
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
      let selectedNode = store.folderIsSelected ? nodes["d:" + store.selectedFolderPath]
        : store.selectedPhoto.flatMap { nodes["f:" + $0.relativePath] }
      if let item = selectedNode {
        let row = outline.row(forItem: item)
        if row >= 0, outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
      }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? (root == nil ? 0 : 1) }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? root! }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.file == nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
      guard let node = item as? Node else { return nil }
      let id = NSUserInterfaceItemIdentifier("file")
      let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
      if cell.textField == nil {
        cell.identifier = id
        let text = NSTextField(labelWithString: ""); text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingMiddle
        let image = NSImageView()
        text.translatesAutoresizingMaskIntoConstraints = false; image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text); cell.addSubview(image); cell.textField = text; cell.imageView = image
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16), text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
      }
      cell.textField?.stringValue = node.name
      cell.imageView?.image = NSImage(systemSymbolName: node.file?.format.symbol ?? "folder", accessibilityDescription: node.file?.format.rawValue ?? "Folder")
      let error = store.remoteFolders?.nodes[node.path]?.error ?? store.localFolders?.errors[node.path]
      if error != nil { cell.imageView?.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Retry") }
      let companion = node.file.flatMap(store.companionDescription)
      cell.toolTip = error ?? (node.path + (companion.map { "\n" + $0 } ?? ""))
      cell.setAccessibilityLabel(node.name + (companion.map { ", " + $0 } ?? ""))
      return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let outline, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
      if let file = node.file { store.selectFile(file) }
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

private final class FileOutline: NSOutlineView {
  var onDelete: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if [51, 117].contains(event.keyCode), modifiers.isEmpty || modifiers == .command { onDelete?(); return }
    super.keyDown(with: event)
  }
}
