import FrameKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct FrameRootView: View {
  @ObservedObject var store: LibraryStore
  let modelContainer: ModelContainer
  @State private var dropTarget = false

  var body: some View {
    GeometryReader { geometry in
      let showsRail = store.showsFolderOutline ?? true
      VStack(spacing: 0) {
        if store.activeRootID != nil {
          FrameToolbar(store: store, showsRail: showsRail).frame(height: 62)
          Divider()
        }
        if showsRail && store.activeRootID != nil && !store.isFocusMode {
          PersistentSplitView(name: "Frame.Workspace.Sidebar", vertical: true, minimumFirst: 180, minimumSecond: 480,
            first: FolderSidebar(store: store), second: MainWorkspace(store: store))
        } else {
          MainWorkspace(store: store)
        }
        if store.activeRootID != nil && !store.rootUnavailable && store.remoteError == nil && !store.isFocusMode
          && (store.viewMode == .contactSheet || store.selectedPhoto?.format.isMedia == true) {
          Divider()
          SelectionActionsBar(store: store)
        }
      }
      .overlay(alignment: .bottom) {
        if let notice = store.notice {
          NoticeView(notice: notice, store: store).padding(.bottom, 62).padding(.horizontal, 20)
        }
      }
    }
    .environmentObject(store.previews)
    .foregroundStyle(FramePalette.ink)
    .background(FramePalette.paper)
    .background(MediaKeyboardShortcuts(store: store))
    .tint(FramePalette.ink)
    .onExitCommand { if !DocumentFocus.ownsKeys(NSApp.keyWindow?.firstResponder) { store.escape() } }
    .overlay {
      if dropTarget {
        RoundedRectangle(cornerRadius: 10).strokeBorder(FramePalette.ink, style: StrokeStyle(lineWidth: 3, dash: [8]))
          .padding(8).allowsHitTesting(false)
      }
    }
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
      guard let provider = providers.first else { return false }
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        guard let url else { return }
        Task { @MainActor in await store.openRoot(url) }
      }
      return true
    }
    .alert("Frame", isPresented: Binding(
      get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
    )) {
      Button("OK") { store.errorMessage = nil }
    } message: { Text(store.errorMessage ?? "") }
    .sheet(isPresented: $store.showsOpenChooser) { OpenFolderChooser(store: store) }
    .sheet(isPresented: Binding(get: { !store.fileActionFailures.isEmpty }, set: {
      if !$0 { store.fileActionFailures = [] }
    })) {
      VStack(alignment: .leading, spacing: 16) {
        Text(store.fileActionSummary).font(.headline)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(store.fileActionFailures) { failure in
              VStack(alignment: .leading, spacing: 4) {
                Text(failure.photo.relativePath).fontWeight(.medium)
                Text(failure.reason).foregroundStyle(FramePalette.muted)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack { Spacer(); Button("Done") { store.fileActionFailures = [] }.keyboardShortcut(.defaultAction) }
      }.font(.system(size: 12)).padding(24).frame(width: 520, height: 360)
        .foregroundStyle(FramePalette.ink).background(FramePalette.paper)
    }
    .task { await store.start(modelContext: modelContainer.mainContext) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.validateSourceAvailability()
    }
  }
}

enum FramePalette {
  static let paper = Color(nsColor: FrameColors.paper)
  static let panel = Color(nsColor: FrameColors.panel)
  static let stage = Color(nsColor: FrameColors.stage)
  static let ink = Color(nsColor: FrameColors.ink)
  static let muted = Color(nsColor: FrameColors.muted)
  static let faint = muted
  static let amber = Color(nsColor: FrameColors.amber)
}

struct FilledButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .padding(.horizontal, 14).padding(.vertical, 8)
      .foregroundStyle(Color(nsColor: enabled ? FrameColors.buttonText : FrameColors.muted))
      .background(Color(nsColor: enabled ? FrameColors.button : FrameColors.panel),
                  in: RoundedRectangle(cornerRadius: 6))
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}

private struct FrameToolbar: View {
  @ObservedObject var store: LibraryStore
  let showsRail: Bool
  private var path: String {
    if store.isRemote { return store.remotePath }
    let root = store.rootURL?.path ?? store.rootName
    return root + (store.filter == .archive ? "  ›  Archive" : store.selectedFolderPath.isEmpty ? "" : "  ›  " + store.selectedFolderPath)
  }
  private var location: String {
    if let photo = store.selectedPhoto, store.viewMode == .inspect {
      return "\(store.rootName) / \(store.documentPath(photo))"
    }
    if store.isRemote { return "\(store.rootName) · \(store.remotePath)" }
    return store.rootName + (store.filter == .archive ? "  ›  Archive" : store.selectedFolderPath.isEmpty ? "" : "  ›  " + store.selectedFolderPath)
  }
  var body: some View {
    HStack(spacing: 16) {
        Button { store.showsFolderOutline = !showsRail } label: {
          Image(systemName: "sidebar.left").font(.system(size: 16))
        }.buttonStyle(.plain).accessibilityLabel(showsRail ? "Hide folders" : "Show folders")
      Button("Open…", action: store.presentOpenChooser).buttonStyle(.bordered)
      Divider().frame(height: 22)
      Text(location)
        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(path).accessibilityLabel(path)
      Spacer(minLength: 8)
      if store.isSearchAvailable {
        if let matches = store.searchMatchCount {
          Text("\(matches) of \(store.folderFileCount)")
            .font(.system(size: 12)).foregroundStyle(FramePalette.muted).lineLimit(1)
        }
        PromptSearchField(store: store)
          .frame(minWidth: 140, idealWidth: 200, maxWidth: 200)
      }
      if store.viewMode == .inspect { FileFilterMenu(store: store) }
      Picker("Layout", selection: Binding(get: { store.viewMode }, set: store.setViewMode)) {
        Text("Preview").tag(FrameViewMode.inspect)
        Text("Grid").tag(FrameViewMode.contactSheet)
      }.pickerStyle(.segmented).labelsHidden().frame(width: 142)
      if store.viewMode == .contactSheet || store.isSelecting {
        Button(store.isSelecting ? "Done" : "Select", action: store.toggleSelectMode)
          .buttonStyle(.bordered).disabled(store.visiblePhotos.isEmpty)
      }
      if store.viewMode == .inspect {
        Button(action: store.toggleInfo) { Image(systemName: "sidebar.right") }
          .buttonStyle(.plain).help("Info").accessibilityLabel("Info")
      }
      if store.isScanning { ProgressView().controlSize(.small) }
      if store.viewMode == .inspect {
        Button(action: store.toggleFullScreen) {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
        }.buttonStyle(.plain).font(.system(size: 11)).help("Full screen (⌃⌘F)")
          .accessibilityLabel("Full screen")
      }
      Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.plain).disabled(!store.canRefresh).help("Refresh folder (⌘R)").accessibilityLabel("Refresh folder")
    }.disabled(store.isFileOperation).padding(.horizontal, 20).background(FramePalette.paper)
  }
}

/// Prompt Search's field: the native search field, with its magnifying glass, a clear button while it has
/// text, and Escape to clear it while it has focus. It lives in the toolbar, which is not rebuilt while
/// someone types in it.
struct PromptSearchField: NSViewRepresentable {
  @ObservedObject var store: LibraryStore
  func makeCoordinator() -> Coordinator { Coordinator(store: store) }
  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.identifier = TypingGuard.searchFieldIdentifier
    field.placeholderString = "Search prompts"
    field.setAccessibilityLabel("Search prompts and notes")
    field.sendsSearchStringImmediately = true
    field.target = context.coordinator
    field.action = #selector(Coordinator.search(_:))
    return field
  }
  func updateNSView(_ field: NSSearchField, context: Context) {
    let coordinator = context.coordinator
    coordinator.store = store
    if field.stringValue != store.searchQuery {
      field.stringValue = store.searchQuery
    }
    field.isEnabled = context.environment.isEnabled
    // A request counts as answered only once the field has the focus; until then each update tries again.
    if coordinator.focusRequests != store.searchFocusRequests, field.window?.makeFirstResponder(field) == true {
      coordinator.focusRequests = store.searchFocusRequests
    }
  }

  @MainActor final class Coordinator: NSObject {
    var store: LibraryStore
    /// The focus requests already answered. A field made later does not answer earlier ones.
    var focusRequests: Int
    init(store: LibraryStore) {
      self.store = store
      focusRequests = store.searchFocusRequests
    }
    @objc func search(_ sender: NSSearchField) {
      store.setSearchQuery(sender.stringValue)
    }
  }
}

struct NoticeView: View {
  let notice: FrameNotice
  @ObservedObject var store: LibraryStore

  var body: some View {
    HStack(spacing: 14) {
      Text(notice.message).lineLimit(2)
      if let actionTitle = notice.actionTitle {
        Button(actionTitle, action: store.performNoticeAction).buttonStyle(.plain).fontWeight(.semibold)
          .underline()
      }
      Button(action: store.dismissNotice) { Image(systemName: "xmark") }
        .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
    }
    .font(.system(size: 12))
    .foregroundStyle(FramePalette.ink)
    .padding(12)
    .background(FramePalette.paper, in: RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).stroke(FramePalette.muted, lineWidth: 1) }
    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
  }
}
