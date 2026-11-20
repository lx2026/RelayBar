import Composition
import HouseStyle
import ImageIO
import MobileCore
import SwiftUI

func imageFile(_ path: String) -> Bool {
  ["png", "jpg", "jpeg", "heic", "webp", "gif", "tif", "tiff"].contains(
    (path as NSString).pathExtension.lowercased())
}

func displayPath(_ path: String, home: String?) -> String {
  guard let home else { return path }
  if path == home { return "~" }
  let prefix = home.hasSuffix("/") ? home : home + "/"
  return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
}

private enum FileKind: Int {
  case document, html, data, image, video, other
  init(_ name: String) {
    switch (name as NSString).pathExtension.lowercased() {
    case "json": self = .data
    case "htm", "html": self = .html
    case "mp4", "mov", "m4v", "webm": self = .video
    default: self = imageFile(name) ? .image : Format.isDocument(name) ? .document : .other
    }
  }
  var glyph: String {
    switch self {
    case .document: "doc.text"
    case .data: "curlybraces"
    case .html: "chevron.left.forwardslash.chevron.right"
    case .image: "photo"
    case .video: "film"
    case .other: "doc"
    }
  }
}

func imagePosition(_ path: String, rows: [FileRow]) -> String? {
  let images = rows.filter { !$0.stamp.directory && imageFile($0.name) }.sorted {
    $0.name.localizedStandardCompare($1.name) == .orderedAscending
  }
  guard let index = images.firstIndex(where: { $0.name == (path as NSString).lastPathComponent })
  else { return nil }
  return "\(index + 1) of \(images.count)"
}

func imageCaption(_ path: String, position: String?) -> String {
  let parent = (path as NSString).deletingLastPathComponent
  return [(parent as NSString).lastPathComponent, position].compactMap { $0 }.joined(
    separator: " · ")
}

private func modifiedTime(_ seconds: UInt32) -> String {
  let date = Date(timeIntervalSince1970: Double(seconds))
  let minutes = max(0, Int(-date.timeIntervalSinceNow / 60))
  if minutes < 60 { return "\(minutes) min" }
  if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
  if minutes < 1440 { return "\(minutes / 60) h" }
  return date.formatted(date: .abbreviated, time: .omitted)
}

struct RowFacts {
  var position: String?
  var image: CGImage?
  var count: Int?
  var stamp: FileStamp
  var preview: DocumentPreview?
}
extension EnvironmentValues {
  @Entry var galleryRows: [String: RowFacts] = [:]
}
private struct RowRead: Equatable {
  let path: String
  let stamp: FileStamp
  let limit: Int
  let connected: Bool
}
struct HistoryLine: View {
  @Environment(\.galleryRows) var facts
  @State private var position: String?
  let visit: Visit
  let files: (any RemoteFiles)?
  let reader: Reader?
  let limit: Int
  var missing: String?
  let open: () -> Void
  @State private var changed = false
  @State private var image: CGImage?
  var body: some View {
    let changed = facts[visit.path].map { $0.stamp != visit.stamp } ?? self.changed
    FileLine(
      icon: FileKind(visit.path).glyph, title: visit.title,
      subtitle: missing.map { "Turn on " + $0 }
        ?? (imageFile(visit.path)
          ? imageCaption(visit.path, position: facts[visit.path]?.position ?? position)
          : (visit.path as NSString).lastPathComponent
            + (changed ? " · changed since you read it" : "")),
      changed: changed, image: limit == 0 ? nil : facts[visit.path]?.image ?? image, action: open
    )
    .task(id: RowRead(path: visit.path, stamp: visit.stamp, limit: limit, connected: reader != nil))
    {
      guard let stamp = try? await files?.stat(visit.path) else { return }
      if imageFile(visit.path),
        let rows = try? await files?.list((visit.path as NSString).deletingLastPathComponent)
      {
        position = imagePosition(visit.path, rows: rows)
      }
      self.changed = stamp != visit.stamp
      image = await smallImage(visit.path, stamp, reader, limit)
    }
  }
}
@MainActor func smallImage(
  _ path: String, _ stamp: FileStamp, _ reader: Reader?, _ limit: Int
) async -> CGImage? {
  guard imageFile(path),
    let bytes = try? await reader?.thumbnail(path: path, stamp: stamp, limit: limit),
    let source = CGImageSourceCreateWithData(bytes as CFData, nil)
  else { return nil }
  return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

struct FolderScreen: View {
  let workspace: HostWorkspace
  let path: String
  let homePath: String?
  @ObservedObject var files: ServicePort<any RemoteFiles>
  let reader: Reader?
  let limit: Int
  let history: [Visit]
  let actions: Registry<FileAction>?
  let open: (Route) -> Void
  @State var rows: [FileRow] = []
  @State private var deletion: RemovalTarget?
  private var order: FolderOrder {
    workspace.profiles.value.folderOrder?[workspace.profile.id] ?? .modified
  }
  private var segments: [String] {
    var paths = [path]
    while let last = paths.last, last != homePath && last != "/" && !last.isEmpty {
      paths.append((last as NSString).deletingLastPathComponent)
    }
    return paths.reversed()
  }
  @State private var query = ""
  @State private var changedOnly = false
  @Environment(\.padReader) var pad
  @Environment(\.pageWidth) var width
  @Environment(\.readerControls) private var controls
  @Environment(\.renderingGallery) private var snapshot
  @State var listOnPad = false
  @State private var grid = false
  @State private var revealed = false
  #if os(iOS)
    @State private var scroll = ScrollPosition()
  #endif
  private var showsHidden: Bool { pad ? workspace.revealedFolder == path : revealed }
  private var cards: Bool { pad && !listOnPad }
  private var saver: Bool {
    workspace.profiles.value.enabled("data-saver", host: workspace.profile.id)
  }
  var hiddenCount: Int { hiddenEntryCount(rows) }

  @State private var message = ""
  var body: some View {
    VStack(spacing: 0) {
      if pad {
        HStack(spacing: 2) {
          Color.clear.frame(width: 52, height: 1)
          if let controls {
            IconButton(label: "Back", symbol: "chevron.left", circle: false, action: controls.back)
              .disabled(!controls.canGoBack)
            IconButton(
              label: "Forward", symbol: "chevron.right", circle: false, action: controls.next
            ).disabled(!controls.canGoForward)
          }
          Spacer()
          toolbar
        }.padding(.horizontal, 12)
      }
      PageScroll {
        if pad {
          GoPage(
            workspace: workspace, fromHome: false, hosts: workspace.profiles.value.hosts,
            states: workspace.states.values, canvas: AnyView(contents), heading: AnyView(header),
            folderPath: path
          )
          .padding(.horizontal, 36)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            header
            contents
          }.padding(.horizontal, 20)
        }
      }
      #if os(iOS)
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) {
          $0.contentOffset.y
        } action: { _, value in
          if pad, !rows.isEmpty { workspace.folderMemory.offsets[path] = value }
        }
      #endif
    }
    .onAppear {
      guard pad, !snapshot else { return }
      listOnPad = workspace.folderMemory.lists[path] ?? false
      changedOnly = workspace.folderMemory.changedOnly[path] ?? false
    }
    .onDisappear {
      revealed = false
      if pad {
        workspace.folderMemory.lists[path] = listOnPad
        workspace.folderMemory.changedOnly[path] = changedOnly
        if workspace.revealedFolder == path { workspace.revealedFolder = nil }
      }
    }
    .modifier(
      RemovalPrompt(
        target: $deletion, completed: { id in rows.removeAll { $0.id == id } },
        failure: { message = $0 })
    )
    .background(HouseColor.paper).task(id: files.generation) {
      do {
        if !snapshot, let service = files.value {
          #if os(iOS)
            let offset = workspace.folderMemory.offsets[path]
          #endif
          let listing = try await service.listing(path)
          try Task.checkCancellation()
          rows = groupedRows(listing.rows)
          message = listing.notice
          #if os(iOS)
            if let offset {
              await Task.yield()
              scroll.scrollTo(y: offset)
            }
          #endif
        }
      } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
  }
  private var toolbar: some View {
    HStack(spacing: 0) {
      IconButton(
        label: "Change layout", symbol: (pad ? cards : grid) ? "list.bullet" : "square.grid.2x2",
        circle: false
      ) { if pad { listOnPad.toggle() } else { grid.toggle() } }
      if !pad {
        IconButton(
          label: "Filter changed files",
          symbol: changedOnly
            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
          circle: false
        ) { changedOnly.toggle() }
      }
      Menu {
        ForEach(FolderOrder.allCases, id: \.self) { choice in
          Button {
            workspace.update {
              if $0.folderOrder == nil { $0.folderOrder = [:] }
              $0.folderOrder?[workspace.profile.id] = choice
            }
          } label: {
            if choice == order {
              Label(choice.rawValue, systemImage: "checkmark")
            } else {
              Text(choice.rawValue)
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          Glyph("arrow.up.arrow.down")
          if pad && width >= 800 {
            Text(order == .modified ? "Date changed" : "Name").mobileFont(14)
          }
        }.frame(minWidth: 44, minHeight: 44)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(HouseColor.ink).fixedSize()
      .accessibilityLabel("Sort by " + order.rawValue)
      if pad {
        Menu {
          Button(changedOnly ? "Show all files" : "Show changed files") { changedOnly.toggle() }
        } label: {
          Glyph("ellipsis.circle").frame(width: 44, height: 44)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(HouseColor.ink).fixedSize()
          .accessibilityLabel("Folder menu")
      }
      if !pad && workspace.canPin && path != homePath {
        workspace.pinButton(.init(path: path, directory: true))
      }
    }.card(22)
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 0) {
      if pad { breadcrumbs }
      HStack {
        Text(path == homePath ? "Home" : (path as NSString).lastPathComponent).mobileFont(
          pad ? 34 : 26, .bold
        )
        .lineLimit(2)
        Spacer(minLength: 2)
        if !pad { toolbar }
      }
      if !pad {
        ViewThatFits(in: .horizontal) {
          breadcrumbs
          ScrollView(.horizontal) { breadcrumbs }.scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)
        }
      } else {
        Text(
          "\(rows.filter { !$0.stamp.directory && !$0.name.hasPrefix(".") }.count) files · \(rows.filter { $0.stamp.directory && !$0.name.hasPrefix(".") }.count) folders"
        ).secondaryText()
      }
    }
  }
  private var contents: some View {
    VStack(alignment: .leading, spacing: 0) {
      if pad, let visit = history.first, (visit.path as NSString).deletingLastPathComponent == path
      {
        ContinueLine(visit: visit) { open(.recent(visit)) }
      }
      if !message.isEmpty { Text(message).secondaryText() }
      if !pad && rows.count > 15 {
        TextField("Filter folder", text: $query).mobileField().mobileFont(16).frame(minHeight: 44)
          .padding(.horizontal, 10).card()
      }
      ForEach([true, false], id: \.self) { folders in
        let group = group(folders)
        if !group.isEmpty {
          let sections =
            pad && !folders && order == .modified
            ? ["Today", "This week", "Earlier"] : [folders ? "Folders" : "Files"]
          ForEach(sections, id: \.self) { title in
            let items = sections.count == 1 ? group : group.filter { period($0) == title }
            if !items.isEmpty {
              Text(title).secondaryText().fontWeight(.semibold).padding(.top, 22).padding(
                .bottom, 8)
              LazyVGrid(
                columns: cards
                  ? Array(
                    repeating: GridItem(.flexible(), spacing: 16),
                    count: width >= 820 ? (folders ? 5 : 3) : 2)
                  : Array(repeating: GridItem(.flexible()), count: grid && !pad ? 2 : 1),
                spacing: cards ? 14 : 0
              ) {
                ForEach(items) { row in item(row) }
              }
            }
          }
        }
      }
      if hiddenCount > 0 && !showsHidden {
        HStack {
          Text(hiddenCount == 1 ? "1 hidden item" : "\(hiddenCount) hidden items").secondaryText()
          Spacer()
          Button("Show") { if pad { workspace.revealedFolder = path } else { revealed = true } }
            .accessibilityLabel("Show hidden items")
        }.frame(minHeight: 44)
      }
    }
  }
  private func period(_ row: FileRow) -> String {
    let date = Date(timeIntervalSince1970: Double(row.stamp.modified ?? 0))
    if Calendar.current.isDateInToday(date) { return "Today" }
    return Date().timeIntervalSince(date) < 7 * 86400 ? "This week" : "Earlier"
  }
  func group(_ folders: Bool) -> [FileRow] {
    sortedFolderFiles(
      rows.filter { row in
        row.stamp.directory == folders && (showsHidden || !row.name.hasPrefix("."))
          && (query.isEmpty || row.name.localizedCaseInsensitiveContains(query))
          && (!changedOnly || visit(row).map { $0.stamp != row.stamp } == true)
      }, order: order)
  }
  private var breadcrumbs: some View {
    HStack(spacing: 0) {
      ForEach(segments, id: \.self) { segment in
        if segment != segments.first {
          Glyph("chevron.right").font(.caption2).foregroundStyle(HouseColor.faint)
        }
        Button(segment == homePath ? "Home" : (segment as NSString).lastPathComponent) {
          open(.folder(segment))
        }
        // Even gaps between names of any length; the row height carries the touch target.
        .secondaryText().padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        .accessibilityLabel("Open " + segment)
      }
    }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).fixedSize(horizontal: true, vertical: false)
  }
  func visit(_ row: FileRow) -> Visit? {
    history.first { $0.path == (path as NSString).appendingPathComponent(row.name) }
  }
  func item(_ row: FileRow) -> some View {
    let child = (path as NSString).appendingPathComponent(row.name)
    let route =
      row.stamp.directory
      ? Route.folder(child) : Route(kind: imageFile(child) ? "image" : "document", path: child)
    func run(_ action: FileAction) {
      do { try action.perform(child) { open(route) } } catch {
        message = error.localizedDescription
      }
    }
    return FolderLine(
      row: row, child: child, cards: cards, saver: saver, visit: visit(row), reader: reader,
      limit: limit, files: files.value
    ) {
      if pad {
        workspace.siblingPaths = group(false).map {
          (path as NSString).appendingPathComponent($0.name)
        }
      }
      if let action = actions?.entries.first(where: { $0.id == "open" }) { run(action) }
    }.contextMenu {
      ForEach(row.companions, id: \.self) { name in
        Button("Open " + name) { open(.document((path as NSString).appendingPathComponent(name))) }
      }
      if let actions {
        FileActionButtons(
          workspace: workspace, registry: actions, row: row, path: child, open: { open(route) },
          follow: { open(.init(kind: "log", path: child)) },
          confirm: { deletion = .init(path: child, action: $0, row: row) },
          failure: { message = $0 })
      }
    }
  }
}

private struct FolderLine: View {
  @Environment(\.galleryRows) var facts
  let row: FileRow
  let child: String
  let cards, saver: Bool
  @State private var preview: DocumentPreview?
  let visit: Visit?
  let reader: Reader?
  let limit: Int
  let files: (any RemoteFiles)?
  let open: () -> Void
  @State private var count: Int?
  @State private var image: CGImage?
  var body: some View {
    let count = facts[child]?.count ?? self.count
    let size = row.stamp.size.map {
      ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)
    }
    let title =
      visit?.title ?? (saver ? nil : (facts[child]?.preview ?? preview)?.title) ?? row.name
    let excerpt =
      visit?.excerpt ?? (saver ? nil : (facts[child]?.preview ?? preview)?.excerpt)
      ?? "Not Opened Yet"
    return Group {
      if cards && !row.stamp.directory {
        Button(action: open) {
          if imageFile(child), let img = facts[child]?.image ?? image, limit > 0 {
            VStack(alignment: .leading) {
              Image(decorative: img, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity)
                .frame(height: 152).background(HouseColor.stage)
              Text(row.name).mobileFont(15, .semibold).padding(8)
            }.card(12)
          } else if FileKind(child) == .document {
            CanvasCard(
              title: title, excerpt: excerpt,
              detail: [row.stamp.modified.map(modifiedTime), row.name].compactMap { $0 }.joined(
                separator: " · "), height: 200)
          } else {
            VStack(alignment: .leading) {
              Glyph(FileKind(child).glyph)
              Text(row.name).mobileFont(17, .semibold)
              Spacer()
              Text(size ?? "").secondaryText()
            }.padding().frame(maxWidth: .infinity, alignment: .leading).frame(height: 200).card(12)
          }
        }
      } else {
        FileLine(
          icon: row.stamp.directory ? "folder" : FileKind(child).glyph,
          title: title + (row.companions.isEmpty ? "" : "  { }"),
          subtitle: row.stamp.directory
            ? count.map { "\($0) " + ($0 == 1 ? "item" : "items") } ?? "Folder"
            : FileKind(child) == .document
              ? [title == row.name ? nil : row.name, excerpt].compactMap { $0 }.joined(
                separator: " · ") : visit.map { _ in row.name } ?? size ?? "",
          time: row.stamp.directory
            ? nil
            : row.stamp.modified.map(modifiedTime),
          changed: visit.map { $0.stamp != row.stamp } ?? false, chevron: row.stamp.directory,
          rule: !cards, image: limit == 0 ? nil : facts[child]?.image ?? image, action: open
        )
        // A folder among cards is a tile: its own border, and no rule beneath it.
        .padding(.horizontal, cards ? 8 : 0).background(
          cards ? HouseColor.card : Color.clear, in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
          if cards { RoundedRectangle(cornerRadius: 12).strokeBorder(HouseColor.line, lineWidth: 1) }
        }
      }
    }
    .task(
      id: RowRead(
        path: child, stamp: row.stamp, limit: saver ? 0 : 1,
        connected: reader != nil && visit == nil), priority: .background
    ) {
      preview = nil
      if !saver, !row.stamp.directory, visit == nil {
        preview = try? await reader?.preview(path: child, stamp: row.stamp)
      }
    }
    .task(id: RowRead(path: child, stamp: row.stamp, limit: limit, connected: reader != nil)) {
      if row.stamp.directory {
        self.count = try? await files?.list(child).count
      } else {
        image = await smallImage(child, row.stamp, reader, limit)
      }
    }
  }
}

func hiddenEntryCount(_ rows: [FileRow]) -> Int { rows.filter { $0.name.hasPrefix(".") }.count }

func sortedFolderFiles(_ rows: [FileRow], order: FolderOrder) -> [FileRow] {
  rows.sorted { a, b in
    if a.stamp.directory != b.stamp.directory { return a.stamp.directory }
    if order == .modified {
      if a.stamp.modified != b.stamp.modified {
        return (a.stamp.modified ?? 0) > (b.stamp.modified ?? 0)
      }
      if !a.stamp.directory && FileKind(a.name) != FileKind(b.name) {
        return FileKind(a.name).rawValue < FileKind(b.name).rawValue
      }
    }
    return a.name.localizedStandardCompare(b.name) == .orderedAscending
  }
}
