import PreviewSupport
import AVKit
import FrameKit
import SwiftUI

/// What the start of the reader's top row holds while the library column is hidden.
enum LeadingControls {
  case none
  /// Room for the window controls, then the show-folders button and the mode switch.
  case windowControls
  /// The show-folders button and the mode switch only, in full screen.
  case controls
}

/// The right column: one top row, then the file or the folder, then a strip while a file operation runs.
struct ReaderColumn: View {
  @ObservedObject var store: LibraryStore
  let leading: LeadingControls

  var body: some View {
    VStack(spacing: 0) {
      content
      if store.isFileOperation { OperationStrip(store: store) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(FramePalette.paper)
    .overlay(alignment: .bottom) {
      if let notice = store.notice {
        NoticeView(notice: notice, store: store)
          .padding(.bottom, store.isFileOperation ? 48 : 16).padding(.horizontal, FrameMetrics.inset)
      }
    }
  }

  @ViewBuilder private var content: some View {
    if store.rootUnavailable {
      MessageRow(store: store, leading: leading)
      WorkspaceMessage(symbol: "folder.badge.questionmark", title: "\(store.rootName) is unavailable",
        detail: "Reconnect the drive, or locate this folder to keep its favorites.") {
        Button("Locate Folder…", action: store.locateRoot).buttonStyle(FilledButtonStyle()).disabled(!store.canOpenLocalFolder)
      }
    } else if store.activeRootID == nil {
      MessageRow(store: store, leading: leading)
      WelcomeView(store: store)
    } else if store.isReadingFolder {
      MessageRow(store: store, leading: leading)
      ProgressView("Reading folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let error = store.remoteError {
      MessageRow(store: store, leading: leading)
      WorkspaceMessage(symbol: "network", title: "Remote folder unavailable", detail: error) {
        HStack(spacing: 12) {
          Button("Open RelayBar", action: store.openRelayBar).buttonStyle(FilledButtonStyle(prominent: false))
          Button("Retry", action: store.refresh).buttonStyle(FilledButtonStyle())
        }
      }
    } else if store.folderReadError != nil {
      MessageRow(store: store, leading: leading)
      EmptyFilesView(store: store)
    } else if store.viewMode == .contactSheet {
      IconsWorkspace(store: store, leading: leading)
    } else if let photo = store.selectedPhoto {
      FileRow(store: store, photo: photo, leading: leading)
      FileView(store: store, photo: photo)
    } else {
      MessageRow(store: store, leading: leading)
      EmptyFilesView(store: store)
    }
  }
}

/// The start of a top row: nothing beside the library column, or the window controls' room and the
/// column's own controls when it is hidden.
struct LeadingRowControls: View {
  @ObservedObject var store: LibraryStore
  let leading: LeadingControls
  var body: some View {
    switch leading {
    case .none: EmptyView()
    case .windowControls, .controls:
      HStack(spacing: 6) {
        if leading == .windowControls { Color.clear.frame(width: FrameMetrics.windowControlsWidth - FrameMetrics.inset - 6) }
        SidebarButton(store: store)
        ModeSwitch(store: store)
      }
      .padding(.trailing, 18)
    }
  }
}

/// A top row carrying only the leading controls, above a message.
private struct MessageRow: View {
  @ObservedObject var store: LibraryStore
  let leading: LeadingControls
  var body: some View {
    HStack(spacing: 0) {
      LeadingRowControls(store: store, leading: leading)
      Spacer(minLength: 0)
    }
    .padding(.leading, leading == .none ? 0 : FrameMetrics.inset)
    .frame(height: FrameMetrics.topRowHeight)
    .background(WindowDragArea())
  }
}

/// Files mode's one top row: the name and kind, Previous and Next with the position, then the file's actions.
private struct FileRow: View {
  @ObservedObject var store: LibraryStore
  let photo: PhotoItem
  let leading: LeadingControls
  var body: some View {
    HStack(spacing: 6) {
      LeadingRowControls(store: store, leading: leading)
      Text(photo.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        .help("\(store.rootName) / \(store.documentPath(photo))").accessibilityLabel(photo.relativePath)
        .padding(.trailing, 2)
      KindChip(text: photo.kindChip)
      if photo.format == .markdown || photo.format == .html {
        SourceSwitch(store: store, renderer: store.documentRenderer).padding(.leading, 12)
      }
      if photo.format.isDocument {
        DocumentProgress(renderer: store.documentRenderer, path: store.documentPath(photo), location: store.documentLocation)
      }
      Spacer(minLength: 12)
      if store.isSelecting {
        Button("Done", action: store.toggleSelectMode).buttonStyle(TextButtonStyle(isOn: true))
          .disabled(store.isFileOperation)
        Button(action: store.toggleCurrentSelection) {
          Image(systemName: store.batchSelection.ids.contains(photo.id) ? "checkmark.circle.fill" : "circle")
        }.buttonStyle(IconButtonStyle())
          .help("Toggle selection (Space)").disabled(!store.hasAvailableSelection)
          .accessibilityLabel(store.batchSelection.ids.contains(photo.id) ? "Selected" : "Select")
      }
      Button { store.navigate(by: -1) } label: { Image(systemName: "chevron.left") }
        .buttonStyle(IconButtonStyle())
        .help("Previous file (← in viewer)").accessibilityLabel("Previous file")
        .disabled(!store.hasAvailableSelection)
      Text(position).font(.system(size: 12).monospacedDigit()).foregroundStyle(FramePalette.muted)
        .lineLimit(1).fixedSize().padding(.horizontal, 2)
      Button { store.navigate(by: 1) } label: { Image(systemName: "chevron.right") }
        .buttonStyle(IconButtonStyle())
        .help("Next file (→ in viewer)").accessibilityLabel("Next file")
        .disabled(!store.hasAvailableSelection)
      Hairline(vertical: true).frame(height: 18).padding(.horizontal, 6)
      // In Select mode the actions reach every checked file, not only the one on show.
      if let count = store.selectionCountLabel {
        Text(count).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize().padding(.trailing, 4)
      }
      FileActions(store: store)
    }
    .padding(.leading, leading == .none ? FrameMetrics.readerLeading : FrameMetrics.inset)
    .padding(.trailing, FrameMetrics.readerTrailing)
    .frame(height: FrameMetrics.topRowHeight)
    .background(WindowDragArea())
  }
  private var position: String {
    let items = store.visiblePhotos
    return "\(items.firstIndex { $0.id == photo.id }.map { $0 + 1 } ?? 0) of \(items.count)"
  }
}

/// Favorite, Archive, Move to Trash and More: what used to sit in the toolbar and the selection bar. In Icons
/// mode they act on the selection.
struct FileActions: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    let favorite = store.allActionPhotosFavorite
    let count = store.actionPhotos.count
    let restoring = store.filter == .archive
    HStack(spacing: 6) {
      Button(action: store.toggleFavorite) { Image(systemName: favorite ? "heart.fill" : "heart") }
        .buttonStyle(IconButtonStyle(tint: favorite ? FramePalette.amber : FramePalette.muted))
        .help("Favorite and next (F)")
        .accessibilityLabel(favorite ? "Unfavorite this image" : "Favorite this image")
        .disabled(!store.canFavorite)
      Button(action: store.archiveSelected) { Image(systemName: restoring ? "arrow.uturn.backward" : "archivebox") }
        .buttonStyle(IconButtonStyle())
        .help(store.groupedActionHelp ?? (restoring ? "Restore selected groups" : "Move selected groups to Archive"))
        .accessibilityLabel(restoring ? "Restore" : "Archive")
        .disabled(!store.canArchive)
      Button(action: store.deleteSelected) { Image(systemName: "trash") }
        .buttonStyle(IconButtonStyle(tint: FramePalette.red))
        .help(store.deleteHelp)
        .accessibilityLabel(store.deleteTitle + (store.isSelecting || count > 1 ? " \(count)" : ""))
        .disabled(!store.canDelete)
      IconMenu(systemImage: "ellipsis", label: "More actions") { MoreActions(store: store) }
    }
  }
}

/// Everything else a file offers, in one menu.
struct MoreActions: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    Button(store.isExporting ? "Exporting…" : "Export Exact Copy…", action: store.exportSelected)
      .disabled(!store.canExport).help(store.exportHelp)
    if let photo = store.selectedPhoto, photo.remote != nil, photo.format.isImage {
      Button("Original", action: store.loadOriginal)
        .disabled(store.isLoadingOriginal || store.originalPreview != nil || !store.hasAvailableSelection)
        .help("Download full-resolution original")
    }
    Button("Full Screen", action: store.toggleFullScreen).disabled(!store.canInspect)
    if store.viewMode == .inspect, store.selectedPhoto?.format.isDocument == true {
      DocumentHistoryItems(renderer: store.documentRenderer)
    }
    Button("Open in Default App", action: store.openSelectedInDefaultApp).disabled(!store.canOpenSelectedInDefaultApp)
    Divider()
    Button(store.showsInfo ? "Hide Details" : "Show Details", action: store.toggleInfo)
      .disabled(store.selectedPhoto == nil)
  }
}

/// The file itself: documents in the reading view, images and video centred with the details rail.
private struct FileView: View {
  @ObservedObject var store: LibraryStore
  let photo: PhotoItem
  private var showsRail: Bool { store.showsInfo && !store.isFocusMode && !store.selectionMissing }
  var body: some View {
    Group {
      if photo.format.isDocument {
        DocumentReader(store: store, renderer: store.documentRenderer, photo: photo, showsRail: showsRail)
      } else {
        MediaStage(photo: photo, store: store, showsRail: showsRail)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Being displayed here is what opening a file means for the changed marker.
    .onAppear { store.noteDisplayed(photo) }
    .onChange(of: photo.contentID) { _, _ in store.noteDisplayed(photo) }
  }
}

/// Rendered or Source, for Markdown and HTML.
private struct SourceSwitch: View {
  @ObservedObject var store: LibraryStore
  @ObservedObject var renderer: DocumentRenderer
  var body: some View {
    HStack(spacing: 2) {
      segment("Rendered", isOn: !renderer.showsSource) { store.setShowsDocumentSource(false) }
      segment("Source", isOn: renderer.showsSource) { store.setShowsDocumentSource(true) }
    }
    .padding(2)
    .background(FramePalette.fill, in: RoundedRectangle(cornerRadius: FrameMetrics.radius, style: .continuous))
    .fixedSize()
    .accessibilityElement(children: .contain).accessibilityLabel("Document view")
  }
  private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 12, weight: isOn ? .medium : .regular))
        .foregroundStyle(isOn ? FramePalette.ink : FramePalette.muted)
        .padding(.horizontal, 10).frame(height: 22)
        .background {
          if isOn {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(FramePalette.card)
              .shadow(color: .black.opacity(0.1), radius: 0.75, y: 1)
              .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(FramePalette.line, lineWidth: 0.5))
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// A document filling the column; Markdown read rendered gets its "On this page" outline beside the article
/// when there is room for both.
private struct DocumentReader: View {
  @ObservedObject var store: LibraryStore
  @ObservedObject var renderer: DocumentRenderer
  let photo: PhotoItem
  let showsRail: Bool
  /// The reading column's 680 points with the page's own 32-point margins, then the rail and its insets.
  static let outlineRoom: CGFloat = 680 + 64 + FrameMetrics.outlineWidth + 16 + 36
  var body: some View {
    GeometryReader { geometry in
      HStack(alignment: .top, spacing: 0) {
        DocumentPreview(photo: photo, store: store)
        if photo.format == .markdown {
          if showsRail, !renderer.showsSource, renderer.hasPageOutline, geometry.size.width >= Self.outlineRoom {
            let visible = !renderer.outline.isEmpty && renderer.isDisplaying(path: store.documentPath(photo), location: store.documentLocation)
            OutlineRail(renderer: renderer, location: "\(store.rootName) / \(store.documentPath(photo))",
                        changed: ChangeTracking.modificationDate(of: photo).map(FrameFormat.relative.string(from:)))
              .opacity(visible ? 1 : 0)
              .allowsHitTesting(visible)
              .accessibilityHidden(!visible)
              .frame(width: FrameMetrics.outlineWidth)
              .padding(.leading, 16).padding(.trailing, 36).padding(.top, 16)
          }
        } else if showsRail {
          DetailsRail(photo: photo, store: store)
            .frame(width: FrameMetrics.railWidth)
            .padding(.leading, 24).padding(.trailing, FrameMetrics.readerLeading)
        }
      }
    }
  }
}

/// "On this page": the Markdown file's second- and third-level headings, the one being read marked, then where
/// the file is and when it changed.
private struct OutlineRail: View {
  @ObservedObject var renderer: DocumentRenderer
  let location: String
  let changed: String?
  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        Text("On this page").font(.system(size: 11, weight: .semibold)).foregroundStyle(FramePalette.muted)
          .frame(height: 20).padding(.bottom, 6)
        ForEach(Array(renderer.outline.enumerated()), id: \.offset) { index, heading in
          let isOn = renderer.activeHeading == index
          Button { renderer.scrollToHeading(index) } label: {
            Text(heading.title).font(.system(size: 12.5, weight: isOn ? .semibold : .regular))
              .foregroundStyle(isOn ? FramePalette.ink : FramePalette.muted)
              .lineLimit(1).truncationMode(.tail)
              .padding(.leading, heading.level == 3 ? 22 : 10)
              .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
              .overlay(alignment: .leading) {
                Rectangle().fill(isOn ? Color(nsColor: .controlAccentColor) : FramePalette.line).frame(width: 2)
              }
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(heading.title)
          .accessibilityAddTraits(isOn ? .isSelected : [])
        }
        VStack(alignment: .leading, spacing: 0) {
          Text(location)
          if let changed { Text(changed) }
        }
        .font(.system(size: 11.5)).lineSpacing(2).foregroundStyle(FramePalette.muted)
        .lineLimit(2).truncationMode(.middle)
        .padding(.top, 16)
      }
      .padding(.top, 10).padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlayScroller()
    }
  }
}

private struct WelcomeView: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38, weight: .ultraLight))
        .foregroundStyle(FramePalette.muted).padding(.bottom, 4)
      Button("Open…", action: store.presentOpenChooser).buttonStyle(FilledButtonStyle())
      Text("or drop a folder").font(.callout).foregroundStyle(FramePalette.muted)
      if !store.recentFolders.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          SectionLabel("Recent")
          ForEach(store.recentFolders) { recent in
            Button {
              Task { await store.openRecent(recent.id) }
            } label: {
              HStack {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 4) {
                  Text(recent.name + (recent.available ? "" : " — Unavailable")).fontWeight(.medium)
                  Text(recent.parentPath).font(.subheadline).foregroundStyle(FramePalette.muted)
                }
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(FramePalette.muted)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }.frame(width: 420).padding(.top, 24)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.bottom, FrameMetrics.topRowHeight)
  }
}

struct WorkspaceMessage<Actions: View>: View {
  let symbol: String
  let title: String
  let detail: String
  @ViewBuilder var actions: () -> Actions
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.largeTitle.weight(.light)).foregroundStyle(FramePalette.muted)
      Text(title).font(.title2.weight(.semibold))
      if !detail.isEmpty {
        Text(detail).font(.callout).foregroundStyle(FramePalette.muted)
          .multilineTextAlignment(.center).frame(maxWidth: 400)
      }
      actions().padding(.top, 4)
    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// While a file operation runs: its progress, how far it has got, and Cancel where it can be cancelled.
private struct OperationStrip: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    HStack(spacing: 10) {
      ProgressView(value: Double(store.operationProgress), total: Double(max(1, store.operationTotal)))
        .frame(width: 100).controlSize(.small)
      Text("\(store.operationTitle) \(store.operationProgress) of \(store.operationTotal)")
        .font(.system(size: 12).monospacedDigit()).foregroundStyle(FramePalette.muted).lineLimit(1)
      Spacer(minLength: 8)
      if store.operationTitle != "Restoring from Trash" && !(store.isRemote && store.operationTitle == "Deleting") {
        Button("Cancel", action: store.cancelFileOperation).controlSize(.small)
      }
    }
    .padding(.leading, FrameMetrics.readerLeading).padding(.trailing, FrameMetrics.readerTrailing)
    .frame(height: 32)
    .background(FramePalette.panel)
    .overlay(alignment: .top) { Hairline() }
  }
}

/// An image centred on the paper with 16 points above it, or the video player, beside the details rail.
private struct MediaStage: View {
  let photo: PhotoItem
  @ObservedObject var store: LibraryStore
  let showsRail: Bool
  @FocusState private var viewerFocused: Bool
  @State private var loadedSize: (id: String, size: CGSize)?
  @Environment(\.displayScale) private var displayScale
  /// The media's pixel size: what the loaded image reports, else the dimensions its metadata gives.
  private var mediaSize: CGSize? {
    if let loadedSize, loadedSize.id == (store.originalPreview ?? photo).contentID { return loadedSize.size }
    guard let value = store.metadata.identity.first(where: { $0.label == "Dimensions" })?.value else { return nil }
    let parts = value.components(separatedBy: " × ").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? CGSize(width: parts[0], height: parts[1]) : nil
  }
  /// The viewer claims the keyboard when it appears or its asset changes, unless the folder tree or a
  /// text control being edited has it: a result arriving while someone types must not move the focus.
  private var mayTakeFocus: Bool {
    let responder = NSApp.keyWindow?.firstResponder
    return !(responder is NSOutlineView) && !TypingGuard.isEditingText(responder)
  }

  var body: some View {
    StageLayout(railWidth: FrameMetrics.railWidth, gap: 48, aspect: store.selectionMissing ? nil : mediaSize.map { $0.width / $0.height }) {
      Group {
        if store.selectionMissing {
          WorkspaceMessage(symbol: "doc.badge.ellipsis", title: "File missing", detail: "") {
            Button("Retry", action: store.refresh).buttonStyle(FilledButtonStyle())
          }
        } else if photo.format.isVideo {
          VideoStage(photo: photo, playback: store.playback)
        } else {
          GeometryReader { geometry in
            let shown = store.originalPreview ?? photo
            LoadedImageView(photo: shown, maxPixelSize: ContactSheetMetrics.previewPixels(
              width: geometry.size.width, height: geometry.size.height, scale: displayScale), alignment: .top,
              onLoad: { loadedSize = (shown.contentID, $0) })
              .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
          }
        }
      }
      .contentShape(Rectangle())
      .focusable().focusEffectDisabled().focused($viewerFocused)
      .onKeyPress { press in
        guard viewerFocused, press.modifiers.isEmpty else { return .ignored }
        switch press.key {
        case .space:
          guard photo.format.isVideo else { return .ignored }
          store.togglePlayback()
        case .return: return .ignored
        case .escape: store.escape()
        default:
          if press.characters.lowercased() == "f" { store.toggleFavorite() }
          else if press.characters.lowercased() == "g" { store.toggleContactSheet() }
          else { return .ignored }
        }
        return .handled
      }
      // Only clicks on the image/background claim the viewer; AVKit retains its controls.
      .onTapGesture { if !photo.format.isVideo { viewerFocused = true } }
      .onAppear { if mayTakeFocus { viewerFocused = true } }
      .onChange(of: photo.id) { _, _ in if mayTakeFocus { viewerFocused = true } }
      if showsRail { DetailsRail(photo: photo, store: store) }
    }
    .padding(.top, 16).padding(.horizontal, 36).padding(.bottom, 24)
  }
}

/// Places the media and the rail side by side and centres the pair, so the rail sits beside the image rather
/// than at the column's edge. An image reports the size it fits at; a player takes all the room it is given.
private struct StageLayout: Layout {
  let railWidth: CGFloat
  let gap: CGFloat
  /// Width over height of the media, when known; without it the media takes all the room beside the rail.
  let aspect: CGFloat?
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let media = subviews.first else { return }
    let rail = subviews.count > 1 ? subviews[1] : nil
    let room = max(0, bounds.width - (rail == nil ? 0 : railWidth + gap))
    let width = aspect.map { min(room, (bounds.height * $0).rounded()) } ?? room
    // A player letterboxes in black, so it gets exactly the video's shape when that is known.
    let height = aspect.map { min(bounds.height, (width / $0).rounded()) } ?? bounds.height
    let total = width + (rail == nil ? 0 : gap + railWidth)
    let x = bounds.minX + max(0, (bounds.width - total) / 2)
    media.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: height))
    rail?.place(at: CGPoint(x: x + width + gap, y: bounds.minY), proposal: ProposedViewSize(width: railWidth, height: bounds.height))
  }
}

struct VideoStage: View {
  let photo: PhotoItem
  @ObservedObject var playback: PlaybackController
  @EnvironmentObject private var previews: FrameComposition
  var body: some View {
    Group {
      if !previews.enabledKinds.contains("video") {
        WorkspaceMessage(symbol: "play.slash", title: "Video preview disabled", detail: "Enable video in Settings.") {}
      } else if let failure = playback.failure {
        WorkspaceMessage(symbol: "play.slash", title: "Video unavailable", detail: failure) {
          if photo.remote == nil {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }.buttonStyle(FilledButtonStyle())
          } else {
            Button("Retry") { previews.preparePlayback(photo, downloadOriginal: true) }.buttonStyle(FilledButtonStyle())
          }
        }
      } else if let player = playback.player {
        NativeVideoPlayer(player: player)
      } else if photo.remote != nil && !playback.isPreparing {
        LoadedImageView(photo: photo, maxPixelSize: 2048)
          .overlay(alignment: .bottom) {
            Button("Play original") { previews.preparePlayback(photo, downloadOriginal: true) }
              .buttonStyle(FilledButtonStyle()).padding(20).help("Download original for playback")
          }
      } else {
        ProgressView(previews.transfers.messages[photo.id] ?? "Loading video…").controlSize(.small)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: previews.playbackSettingsID(for: photo)) { _, _ in
        if previews.enabledKinds.contains("video"), photo.remote == nil || previews.link.isConnected { previews.preparePlayback(photo) }
      }
  }
}

private struct NativeVideoPlayer: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .floating
    view.videoGravity = .resizeAspect
    view.showsFullScreenToggleButton = false
    view.player = player
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct LoadedImageView: View {
  let photo: PhotoItem
  let maxPixelSize: Int
  var alignment: Alignment = .center
  var onLoad: ((CGSize) -> Void)?
  @State private var image: CGImage?
  @State private var loadedID: String?
  @State private var failed = false
  @State private var failureMessage: String?
  @EnvironmentObject private var previews: FrameComposition
  @State private var retry = 0
  @State private var previewSession: PreviewSession<FramePreviewContent>?

  var body: some View {
    ZStack(alignment: alignment) {
      if loadedID == photo.contentID, let image {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
      } else if failed && loadedID == photo.contentID {
        WorkspaceMessage(symbol: "photo.badge.exclamationmark", title: "Can’t display this image",
          detail: failureMessage ?? "The file may be damaged or unavailable.") {
          if photo.remote == nil {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }.buttonStyle(FilledButtonStyle())
          } else {
            Button("Retry") {
              Task {
                do { try await previews.link.connect(); failed = false; retry += 1 }
                catch { failureMessage = error.localizedDescription }
              }
            }.buttonStyle(FilledButtonStyle())
          }
        }
      } else {
        VStack(spacing: 8) {
          ProgressView().controlSize(.small)
          if let message = previews.transfers.messages[photo.id] { Text(message).font(.caption).foregroundStyle(FramePalette.muted) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: "\(photo.contentID)|\(maxPixelSize / 64)|\(retry)|\(previews.settingsID(for: photo))") {
      if loadedID != photo.contentID { image = nil; failed = false }
      try? await Task.sleep(for: .milliseconds(50))
      guard !Task.isCancelled else { return }
      let old = previewSession; previewSession = nil; old?.invalidate(); await old?.close()
      do {
        let session = try await previews.image(photo, pixels: maxPixelSize)
        guard !Task.isCancelled, !session.isClosed else { await session.close(); return }
        previewSession = session
        let id = session.id
        session.onClose = {
          guard previewSession?.id == id else { return }
          previewSession = nil; image = nil; failed = true
          failureMessage = photo.remote != nil && !previews.link.isConnected ? previews.link.message : "Preview disabled."
        }
        image = session.content.image; failureMessage = nil; failed = image == nil
        if let image { onLoad?(CGSize(width: image.width, height: image.height)) }
      } catch {
        guard !Task.isCancelled else { return }
        image = nil; failed = true; failureMessage = error.localizedDescription
      }
      loadedID = photo.contentID
    }
    .onDisappear {
      let session = previewSession; previewSession = nil; session?.invalidate()
      if let session { Task { await session.close() } }
    }
  }
}
