import PreviewSupport
import AVKit
import FrameKit
import SwiftUI

struct MainWorkspace: View {
  @ObservedObject var store: LibraryStore

  var body: some View {
    Group {
      if store.rootUnavailable {
        WorkspaceMessage(symbol: "folder.badge.questionmark", title: "\(store.rootName) is unavailable",
          detail: "Reconnect the drive, or locate this folder to keep its favorites.") {
          Button("Locate Folder…", action: store.locateRoot).buttonStyle(FilledButtonStyle()).disabled(!store.canOpenLocalFolder)
        }
      } else if store.activeRootID == nil {
        WelcomeView(store: store)
      } else if store.isReadingFolder {
        ProgressView("Reading folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = store.remoteError {
        WorkspaceMessage(symbol: "network", title: "Remote folder unavailable", detail: error) {
          HStack {
            Button("Open RelayBar", action: store.openRelayBar)
            Button("Retry", action: store.refresh).buttonStyle(FilledButtonStyle())
          }
        }
      } else if store.folderReadError != nil {
        EmptyFilesView(store: store)
      } else if store.viewMode == .contactSheet {
        ContactSheetWorkspace(store: store)
      } else {
        if store.showsInfo, !store.isFocusMode, let photo = store.selectedPhoto, !store.selectionMissing {
          PersistentSplitView(name: "Frame.Preview.Info", vertical: true, minimumFirst: 360, minimumSecond: 230,
            first: preview, second: MetadataPanel(photo: photo, store: store))
        } else {
          preview
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(FramePalette.paper)
  }
  @ViewBuilder private var preview: some View {
    if let photo = store.selectedPhoto {
      if photo.format.isDocument { DocumentPreview(photo: photo, store: store) }
      else { MediaStage(photo: photo, store: store) }
    } else { EmptyFilesView(store: store) }
  }
}

private struct WelcomeView: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38, weight: .ultraLight))
        .foregroundStyle(FramePalette.muted)
      Button("Open…", action: store.presentOpenChooser).buttonStyle(FilledButtonStyle())
      Text("or drop a folder").font(.system(size: 12)).foregroundStyle(FramePalette.muted)
      if !store.recentFolders.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(FramePalette.muted)
          ForEach(store.recentFolders) { recent in
            Button {
              Task { await store.openRecent(recent.id) }
            } label: {
              HStack {
                Image(systemName: "folder")
                VStack(alignment: .leading, spacing: 3) {
                  Text(recent.name + (recent.available ? "" : " — Unavailable")).fontWeight(.medium)
                  Text(recent.parentPath).font(.system(size: 11)).foregroundStyle(FramePalette.muted)
                }
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(FramePalette.muted)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }.frame(width: 420).padding(.top, 18)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct WorkspaceMessage<Actions: View>: View {
  let symbol: String
  let title: String
  let detail: String
  @ViewBuilder var actions: () -> Actions
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(FramePalette.muted)
      Text(title).font(.system(size: 17, weight: .semibold))
      if !detail.isEmpty {
        Text(detail).font(.system(size: 12)).foregroundStyle(FramePalette.muted)
          .multilineTextAlignment(.center).frame(maxWidth: 400)
      }
      actions().padding(.top, 6)
    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct MediaStage: View {
  let photo: PhotoItem
  @ObservedObject var store: LibraryStore
  @FocusState private var viewerFocused: Bool
  /// The viewer claims the keyboard when it appears or its asset changes, unless the folder tree or a
  /// text control being edited has it: a result arriving while someone types must not move the focus.
  private var mayTakeFocus: Bool {
    let responder = NSApp.keyWindow?.firstResponder
    return !(responder is NSOutlineView) && !TypingGuard.isEditingText(responder)
  }

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if store.selectionMissing {
          WorkspaceMessage(symbol: "doc.badge.ellipsis", title: "File missing", detail: "") {
            Button("Retry", action: store.refresh).buttonStyle(FilledButtonStyle())
          }
        } else if photo.format.isVideo {
          VideoStage(photo: photo, playback: store.playback)
        } else {
          GeometryReader { geometry in
            LoadedImageView(photo: store.originalPreview ?? photo, maxPixelSize: ContactSheetMetrics.previewPixels(
              width: geometry.size.width, height: geometry.size.height, scale: 2))
              .padding(24).frame(width: geometry.size.width, height: geometry.size.height)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

      HStack(spacing: 14) {
        Text(photo.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
        Spacer(minLength: 6)
        if store.isSelecting {
          Button(action: store.toggleCurrentSelection) {
            Label(store.batchSelection.ids.contains(photo.id) ? "Selected" : "Select",
              systemImage: store.batchSelection.ids.contains(photo.id) ? "checkmark.circle.fill" : "circle")
          }.help("Toggle selection (Space)").disabled(!store.hasAvailableSelection)
        }
        if photo.remote != nil && !photo.format.isVideo {
          Button("Original",
            action: store.loadOriginal).disabled(store.isLoadingOriginal || store.originalPreview != nil)
            .help("Download full-resolution original")
        }
        if store.isFocusMode {
          Button(action: store.toggleFavorite) {
            Image(systemName: store.isFavorite(photo) ? "heart.fill" : "heart")
              .foregroundStyle(store.isFavorite(photo) ? FramePalette.amber : FramePalette.ink)
              .frame(width: 30, height: 30)
          }.help("Favorite and next (F)")
            .accessibilityLabel(store.isFavorite(photo) ? "Unfavorite this image" : "Favorite this image")
            .disabled(!store.canFavorite)
          Group {
            Button(store.deleteTitle + (store.isSelecting ? " \(store.actionPhotos.count)" : ""), action: store.deleteSelected)
              .help(store.deleteHelp)
              .accessibilityLabel(store.deleteTitle + (store.isSelecting ? " \(store.actionPhotos.count) selected" : "")).disabled(!store.canDelete)
          }
          Divider().frame(height: 16)
        }
        Button { store.navigate(by: -1); viewerFocused = true } label: { Image(systemName: "chevron.left") }
          .help("Previous file (← in viewer)").accessibilityLabel("Previous file")
          .disabled(!store.hasAvailableSelection)
        Text(position).font(.system(size: 11).monospacedDigit()).foregroundStyle(FramePalette.muted)
        Button { store.navigate(by: 1); viewerFocused = true } label: { Image(systemName: "chevron.right") }
          .help("Next file (→ in viewer)").accessibilityLabel("Next file")
          .disabled(!store.hasAvailableSelection)
      }
      .buttonStyle(.plain).padding(.horizontal, 20).frame(height: 44)
      .background(FramePalette.panel)
    }.background(FramePalette.stage)
  }
  private var position: String {
    let items = store.visiblePhotos
    return "\(items.firstIndex { $0.id == photo.id }.map { $0 + 1 } ?? 0) / \(items.count)"
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
        NativeVideoPlayer(player: player).padding(20)
      } else if photo.remote != nil && !playback.isPreparing {
        LoadedImageView(photo: photo, maxPixelSize: 2048)
          .overlay(alignment: .bottom) {
            Button("Play original") { previews.preparePlayback(photo, downloadOriginal: true) }
              .buttonStyle(FilledButtonStyle()).padding(20).help("Download original for playback")
          }.padding(20)
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
  @State private var image: CGImage?
  @State private var loadedID: String?
  @State private var failed = false
  @State private var failureMessage: String?
  @EnvironmentObject private var previews: FrameComposition
  @State private var retry = 0
  @State private var previewSession: PreviewSession<FramePreviewContent>?

  var body: some View {
    ZStack {
      if loadedID == photo.contentID, let image {
        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
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
        }
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
