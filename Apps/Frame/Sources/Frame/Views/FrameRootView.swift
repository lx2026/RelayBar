import FrameKit
import HouseStyle
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Two full-height columns: the library on the panel colour, the file or folder on the paper colour.
struct FrameRootView: View {
  @ObservedObject var store: LibraryStore
  let modelContainer: ModelContainer
  @State private var dropTarget = false
  @State private var isFullScreen = false

  var body: some View {
    let showLibrary = (store.showsFolderOutline ?? true) && !store.isFocusMode
    let leading: LeadingControls = showLibrary || store.isFocusMode ? .none : (isFullScreen ? .controls : .windowControls)
    ColumnSplitView(
      showsFirst: showLibrary,
      first: LibraryColumn(store: store).environmentObject(store.previews),
      second: ReaderColumn(store: store, leading: leading).environmentObject(store.previews)
    )
    .ignoresSafeArea()
    .background(WindowChrome(isFullScreen: $isFullScreen))
    // Leaving full screen by any means, the green button included, ends the full-screen viewer.
    .onChange(of: isFullScreen) { _, value in store.fullScreenDidChange(value) }
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
          }.frame(maxWidth: .infinity, alignment: .leading).overlayScroller()
        }
        HStack { Spacer(); Button("Done") { store.fileActionFailures = [] }.keyboardShortcut(.defaultAction) }
      }.font(.callout).padding(24).frame(width: 520, height: 360)
        .foregroundStyle(FramePalette.ink).background(FramePalette.paper)
    }
    .task { await store.start(modelContext: modelContainer.mainContext) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.validateSourceAvailability()
    }
  }
}

/// The house palette for SwiftUI. A view that reads one of these in its body redraws when the form changes.
enum FramePalette {
  static var paper: Color { HouseColor.paper }
  static var panel: Color { HouseColor.panel }
  static var stage: Color { HouseColor.stage }
  static var card: Color { HouseColor.card }
  static var ink: Color { HouseColor.ink }
  static var muted: Color { HouseColor.muted }
  static var amber: Color { HouseColor.amber }
  static var red: Color { HouseColor.red }
  static var line: Color { HouseColor.line }
  static var fill: Color { HouseColor.fill }
  static var button: Color { HouseColor.button }
  static var buttonText: Color { HouseColor.buttonText }
}

/// Shared sizes on a 4-point rhythm: both columns' top rows, the footer and the controls share them.
enum FrameMetrics {
  static let inset: CGFloat = 16
  static let barHeight: CGFloat = 44
  static let topRowHeight: CGFloat = 52
  static let footerHeight: CGFloat = 40
  static let radius: CGFloat = 7
  /// The reader column's leading and trailing insets in its top row.
  static let readerLeading: CGFloat = 28
  static let readerTrailing: CGFloat = 14
  /// Room the window controls take at the start of a top row: their inset, three 12-point lights 8 points
  /// apart, and 10 points after them.
  static let windowControlsWidth: CGFloat = 78
  static let windowControlPitch: CGFloat = 20
  static let railWidth: CGFloat = 240
  static let outlineWidth: CGFloat = 200
}

/// The one emphasised action of a surface; `prominent: false` gives its neutral companion the same shape.
struct FilledButtonStyle: ButtonStyle {
  var prominent = true
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .padding(.horizontal, FrameMetrics.inset).frame(minHeight: 28)
      .foregroundStyle(!enabled ? FramePalette.muted : prominent ? FramePalette.buttonText : FramePalette.ink)
      .background(enabled && prominent ? FramePalette.button : FramePalette.panel,
                  in: RoundedRectangle(cornerRadius: FrameMetrics.radius))
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}

/// Borderless symbol buttons: one glyph size, a 28-point square, a faint fill under the pointer and when on.
struct IconButtonStyle: ButtonStyle {
  var size: CGFloat = 28
  var tint: Color = FramePalette.muted
  var isOn = false
  func makeBody(configuration: Configuration) -> some View {
    IconButtonBody(configuration: configuration, size: size, tint: tint, isOn: isOn)
  }
}

private struct IconButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let size: CGFloat
  let tint: Color
  let isOn: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovered = false
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: FrameMetrics.radius, style: .continuous)
    configuration.label
      .font(.system(size: size < 28 ? 11 : 14)).imageScale(.medium)
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(shape.fill(isOn || (enabled && (hovered || configuration.isPressed)) ? FramePalette.fill : .clear))
      .contentShape(shape)
      .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.7 : 1)
      .onHover { hovered = $0 }
  }
}

/// A menu that looks like an icon button.
struct IconMenu<Content: View>: View {
  let systemImage: String
  let label: String
  @ViewBuilder var content: () -> Content
  var body: some View {
    Menu(content: content) {
      Image(systemName: systemImage).font(.system(size: 14)).foregroundStyle(FramePalette.muted)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .frame(width: 28, height: 28)
    .accessibilityLabel(label).help(label)
  }
}

/// The kind of a file in capitals on a small ink chip.
struct KindChip: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 9.5, weight: .bold)).tracking(0.3)
      .foregroundStyle(FramePalette.paper)
      .padding(.horizontal, 5).frame(height: 16)
      .background(FramePalette.ink, in: RoundedRectangle(cornerRadius: 4))
      .fixedSize()
  }
}

/// A one-point rule in the line colour.
struct Hairline: View {
  var vertical = false
  var body: some View {
    FramePalette.line.frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
  }
}

/// The one treatment for section labels (Recent, Local).
struct SectionLabel: View {
  let title: String
  init(_ title: String) { self.title = title }
  var body: some View {
    Text(title).textCase(.uppercase).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(FramePalette.muted)
  }
}

/// Files shows one file; Icons shows the folder as thumbnails.
struct ModeSwitch: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    // The labels go before the switch is squeezed, so it never truncates.
    ViewThatFits(in: .horizontal) {
      segments(titled: true)
      segments(titled: false)
    }
  }
  private func segments(titled: Bool) -> some View {
    HStack(spacing: 2) {
      segment("Files", systemImage: "list.bullet", mode: .inspect, titled: titled)
      segment("Icons", systemImage: "square.grid.2x2", mode: .contactSheet, titled: titled)
    }
    .fixedSize()
    .padding(2)
    .background(FramePalette.fill, in: RoundedRectangle(cornerRadius: FrameMetrics.radius, style: .continuous))
    .disabled(store.activeRootID == nil || store.isFileOperation)
    .accessibilityElement(children: .contain).accessibilityLabel("View")
  }
  private func segment(_ title: String, systemImage: String, mode: FrameViewMode, titled: Bool) -> some View {
    let isOn = store.viewMode == mode && store.activeRootID != nil
    return Button { store.setViewMode(mode) } label: {
      HStack(spacing: 4) {
        Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
        if titled { Text(title).font(.system(size: 12, weight: isOn ? .medium : .regular)) }
      }
      .foregroundStyle(isOn ? FramePalette.ink : FramePalette.muted)
      .padding(.horizontal, titled ? 8 : 9).frame(height: 24)
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
    .accessibilityLabel(title)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .help(mode == .inspect ? "Show one file" : "Show the folder as icons (G in viewer)")
  }
}

/// Shows or hides the library column.
struct SidebarButton: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    let shows = store.showsFolderOutline ?? true
    Button { store.showsFolderOutline = !shows } label: { Image(systemName: "sidebar.left") }
      .buttonStyle(IconButtonStyle())
      .accessibilityLabel(shows ? "Hide folders" : "Show folders")
      .help(shows ? "Hide folders" : "Show folders")
  }
}

/// Prompt Search's field: the native search field, with a clear button while it has text and Escape to clear it
/// while it has focus. It sits above the tree, which is not rebuilt while someone types in it.
struct PromptSearchField: NSViewRepresentable {
  @ObservedObject var store: LibraryStore
  func makeCoordinator() -> Coordinator { Coordinator(store: store) }
  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.identifier = TypingGuard.searchFieldIdentifier
    field.placeholderString = "Search"
    field.setAccessibilityLabel("Search prompts and notes")
    field.sendsSearchStringImmediately = true
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13)
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
    HStack(spacing: 12) {
      Text(notice.message).lineLimit(2)
      if let actionTitle = notice.actionTitle {
        Button(actionTitle, action: store.performNoticeAction).buttonStyle(.plain).fontWeight(.semibold)
          .underline()
      }
      Button(action: store.dismissNotice) { Image(systemName: "xmark") }
        .buttonStyle(IconButtonStyle(size: 20)).accessibilityLabel("Dismiss notice")
    }
    .font(.callout)
    .foregroundStyle(FramePalette.ink)
    .padding(.vertical, 8).padding(.leading, 12).padding(.trailing, 8)
    .background(FramePalette.paper, in: RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).stroke(FramePalette.muted, lineWidth: 1) }
    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
  }
}
