import PreviewSupport
import Composition
import HouseStyle
import MobileCore
import SwiftUI

struct PadSelection: Codable, Equatable {
  static func restores(_ timestamp: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
    timestamp > 0 && (0..<600).contains(now - timestamp)
  }
  var markedFolder: String? {
    guard let route = treeSelection else { return nil }
    switch route.kind {
    case "folder": return route.path
    case "document", "image", "log": return (route.path as NSString).deletingLastPathComponent
    default: return nil
    }
  }
  var selectedBeside: Bool?
  var treeSelection: Route? { selectedBeside == true ? beside ?? primary : primary }
  var sidebarVisible: Bool?
  private static let start = Route(kind: "start", path: "")
  var primary: Route?
  var beside: Route?
  var fraction = 0.45
  var previous: [Route] = []
  var forward: [Route] = []
  mutating func back() {
    guard let last = previous.popLast() else { return }
    forward.append(primary ?? Self.start)
    selectedBeside = false
    primary = last == Self.start ? nil : last
    if beside == last { beside = nil }
  }
  mutating func next() {
    guard let next = forward.popLast() else { return }
    previous.append(primary ?? Self.start)
    selectedBeside = false
    primary = next == Self.start ? nil : next
    if beside == next { beside = nil }
  }
  mutating func select(_ route: Route, beside alternate: Bool) {
    if alternate, let primary, route != primary {
      selectedBeside = true
      sidebarVisible = false
      beside = route
    } else {
      if (primary ?? Self.start) != route {
        previous = Array((previous + [primary ?? Self.start]).suffix(50))
        forward = []
      }
      selectedBeside = false
      primary = route.kind == "start" ? nil : route
      beside = nil
    }
  }
  mutating func resize(_ value: Double) { fraction = min(0.72, max(0.28, value)) }
}

struct PadWorkspace<Primary: View, Secondary: View>: View {
  let workspace: HostWorkspace
  @Binding var selection: PadSelection
  let pick: (Route, Bool) -> Void
  let service: (ServiceAddress, Bool) -> Void
  @ViewBuilder let primary: () -> Primary
  @ViewBuilder let secondary: () -> Secondary
  private var showSidebar: Bool {
    choosingBeside || (!focused && (selection.sidebarVisible ?? (selection.beside == nil)))
  }
  @State private var newPort = ""
  @State private var focused = false
  @State private var choosingBeside = false
  @State private var initialFraction: Double?
  var body: some View {
    HStack(spacing: 0) {
      if showSidebar {
        sidebar
        Divider()
      }
      GeometryReader { geometry in
        HStack(spacing: 0) {
          primaryPane
            .environment(
              \.pageWidth,
              selection.beside == nil
                ? geometry.size.width : (geometry.size.width - 12) * selection.fraction
            )
            .frame(
              width: selection.beside == nil
                ? geometry.size.width : (geometry.size.width - 12) * selection.fraction)
          if selection.beside != nil {
            Rectangle().fill(HouseColor.line).frame(width: 1).frame(width: 12).contentShape(
              Rectangle()
            )
            .gesture(
              DragGesture(coordinateSpace: .global).onChanged { drag in
                let start = initialFraction ?? selection.fraction
                initialFraction = start
                selection.resize(start + drag.translation.width / max(1, geometry.size.width - 12))
              }.onEnded { _ in initialFraction = nil }
            )
            .accessibilityLabel("Page divider").accessibilityAdjustableAction { direction in
              selection.resize(selection.fraction + (direction == .increment ? 0.05 : -0.05))
            }
            secondary().environment(\.padReader, true)
              .environment(
                \.closePane,
                PadClose {
                  selection.beside = nil
                }
              )
              .overlay(alignment: .topTrailing) {
                if selection.beside?.kind != "service" {
                  IconButton(label: "Close second page", symbol: "xmark") { selection.beside = nil }
                }
              }
          }
        }
      }
    }.background(HouseColor.paper)
      .onChange(of: selection.primary) {
        focused = false
        choosingBeside = false
      }
      .background {
        Button("Open location", action: workspace.showLocation)
          .keyboardShortcut("k", modifiers: .command).opacity(0).accessibilityHidden(true)
      }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button(action: workspace.hosts) {
          HStack {
            StatusMark(state: workspace.state)
            Text(workspace.profile.host).mobileFont(18, .bold)
            Glyph("chevron.down")
          }
          .frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel("Switch host")
        Spacer()
        IconButton(
          label: "Settings", symbol: "gearshape", circle: false, action: workspace.settings)
      }.padding(.horizontal, 8)
      Button {
        selection.select(.init(kind: "start", path: ""), beside: false)
        choosingBeside = false
      } label: {
        sidebarLabel("Start", "safari", selected: selection.treeSelection == nil)
      }
      Text("Places").secondaryText().padding(.horizontal, 8).padding(.top, 8)
      PageScroll {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(roots, id: \.self) { root in
            PlaceRow(
              workspace: workspace, path: root, selected: selection.markedFolder, roots: roots,
              pick: { pick(.folder($0), false) })
          }
        }
      }
      if choosingBeside {
        HStack {
          TextField("Port", text: $newPort).mobileField().onSubmit { openPortBeside() }
          Button("Open", action: openPortBeside).disabled(
            UInt16(newPort) == nil || UInt16(newPort) == 0)
          Button("Cancel") { choosingBeside = false }
        }.padding(8).card(10)
      }
      Text("Websites").secondaryText().padding(.horizontal, 8)
      ForEach(workspace.serviceList, id: \.self) { address in
        Button {
          service(address, choosingBeside)
          choosingBeside = false
        } label: {
          HStack {
            // Verbatim: an interpolated number in a Text is formatted for the locale ("6,006").
            Text(verbatim: ":" + String(address.port)).font(.caption.monospaced())
            Text(workspace.websiteTitle(address)).mobileFont(15)
            Spacer()
          }.padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
            .background(
              isSelected(address) ? HouseColor.fill : Color.clear,
              in: RoundedRectangle(cornerRadius: 8))
        }.contextMenu { Button("Open beside reader") { service(address, true) } }
      }
    }.padding(.horizontal, 10).padding(.bottom, 18).frame(width: 263).background(HouseColor.panel)
  }
  private func openPortBeside() {
    guard let port = UInt16(newPort), port > 0 else { return }
    service(ServiceAddress(port: port), true)
    newPort = ""
    choosingBeside = false
  }
  private func isSelected(_ address: ServiceAddress) -> Bool {
    guard let page = selection.treeSelection, page.kind == "service" else { return false }
    return
      (ServiceAddress.parse(page.path, profile: workspace.profile, kind: "address")
      ?? ServiceAddress.external(page.path, profile: workspace.profile))?.saved == address.saved
  }
  private var roots: [String] {
    let paths =
      [workspace.homePath].compactMap { $0 }
      + workspace.pinned.filter {
        $0.directory == true && !($0.path as NSString).lastPathComponent.hasPrefix(".")
      }.map(\.path)
    if let path = selection.markedFolder,
      !paths.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") })
    {
      return paths + [path]
    }
    return paths
  }

  /// A lone reader has its own top bar, so the sidebar button shares that bar instead of taking a row.
  private var readerOwnsBar: Bool {
    ["document", "image", "folder", "service"].contains(selection.primary?.kind ?? "")
  }
  private var primaryPane: some View {
    primary().environment(\.padReader, true)
      .environment(\.readerFocused, focused)
      .environment(\.splitReader, selection.beside != nil)
      .environment(
        \.readerControls,
        PadControls(
          canGoBack: !selection.previous.isEmpty, canGoForward: !selection.forward.isEmpty,
          back: { selection.back() },
          next: { selection.next() },
          open: { pick(.document($0), false) },
          split: {
            choosingBeside.toggle()
          }, focus: { focused.toggle() }, leadingInset: readerOwnsBar ? 44 : 0)
      )
      .padding(.top, readerOwnsBar ? 0 : 44)
      .overlay(alignment: .topLeading) {
        IconButton(
          label: showSidebar ? "Hide sidebar" : "Show sidebar", symbol: "sidebar.left",
          circle: false
        ) {
          let visible = showSidebar
          focused = false
          selection.sidebarVisible = !visible
          choosingBeside = false
        }.padding(.horizontal, 12)
      }
  }
}

@MainActor private func sidebarLabel(_ name: String, _ icon: String, selected: Bool) -> some View {
  Label(name, systemImage: icon).mobileFont(15).padding(.leading, 10)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
    .background(selected ? HouseColor.fill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityAddTraits(selected ? .isSelected : [])
}

/// One place in the sidebar. It is marked while the page shows it or anything inside it.
private struct PlaceRow: View {
  let workspace: HostWorkspace
  let path: String
  let selected: String?
  let roots: [String]
  let pick: (String) -> Void
  var body: some View {
    // The deepest place that holds the page owns the mark, so a pinned subfolder wins over Home.
    let owner = roots.filter {
      selected == $0 || selected?.hasPrefix($0 == "/" ? "/" : $0 + "/") == true
    }.max { $0.count < $1.count }
    Button {
      pick(path)
    } label: {
      sidebarLabel(
        path == workspace.homePath ? "Home" : (path as NSString).lastPathComponent,
        path == workspace.homePath ? "house" : "folder", selected: owner == path)
    }
  }
}

struct PadClose { let action: @MainActor @Sendable () -> Void }

struct PadControls {
  let canGoBack, canGoForward: Bool
  let back, next: @MainActor @Sendable () -> Void
  var open: @MainActor @Sendable (String) -> Void
  var split: @MainActor @Sendable () -> Void
  var focus: @MainActor @Sendable () -> Void = {}
  /// Room the reader's top bar leaves at its leading edge for the sidebar button drawn over it.
  var leadingInset: CGFloat = 0
}
extension EnvironmentValues {
  @Entry var readerControls: PadControls?
  @Entry var pageWidth: CGFloat = 1112
  @Entry var readerFocused = false
  @Entry var splitReader = false
  @Entry var closePane: PadClose?
  @Entry var padReader = false
}

struct PadStart: View {
  let workspace: HostWorkspace
  @Environment(\.pageWidth) var width
  var galleryPictures: [ServiceAddress: CGImage] = [:]
  @Environment(\.galleryRows) private var facts
  @State private var thumbnails: [String: CGImage] = [:]
  @State var pictures: [ServiceAddress: CGImage] = [:]
  var query = ""
  var hits: [NameHit] = []
  var body: some View {
    PageScroll {
      GoPage(
        workspace: workspace, fromHome: false, hosts: workspace.profiles.value.hosts,
        states: workspace.states.values, canvas: AnyView(sections), query: query, hits: hits
      )
      .padding(.horizontal, 36).padding(.top, 48)
    }
  }
  private var sections: some View {
    VStack(alignment: .leading, spacing: 30) {
      if let visit = workspace.visits.first {
        ContinueLine(visit: visit) { workspace.push(.recent(visit)) }
      }
      section("Websites", minimum: 202) {
        ForEach(workspace.serviceList, id: \.self) { address in
          Button {
            workspace.openService(address)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              ZStack {
                HouseColor.fill
                if let picture = galleryPictures[address] ?? pictures[address] {
                  Image(decorative: picture, scale: 1).resizable().scaledToFill()
                } else {
                  Glyph("globe").foregroundStyle(HouseColor.faint)
                }
              }.frame(height: 76).clipped()
              Text(workspace.websiteTitle(address)).mobileFont(15, .semibold).padding(
                .horizontal, 12)
              Text(verbatim: ":" + String(address.port)).secondaryText().padding(.horizontal, 12)
                .padding(.bottom, 8)
            }.card(12).clipShape(RoundedRectangle(cornerRadius: 12))
              .task(id: workspace.pictureRevision) {
                pictures[address] = await workspace.websitePicture(address)
              }
          }
        }
        Button(action: workspace.showLocation) {
          VStack {
            Glyph("plus")
            Text("Open a port").mobileFont(15, .semibold)
            Text("Any port on " + workspace.profile.host).secondaryText()
          }
          .frame(maxWidth: .infinity, minHeight: 130).card(12)
        }
      }
      if !workspace.visits.isEmpty {
        section("Recent", minimum: 250) {
          ForEach(workspace.visits.prefix(6), id: \.path) { visit in
            Button {
              workspace.push(.recent(visit))
            } label: {
              CanvasCard(
                title: visit.title, excerpt: visit.excerpt,
                detail: (visit.path as NSString).deletingLastPathComponent.components(
                  separatedBy: "/"
                ).suffix(2).joined(separator: " › ")
                  + " · " + visit.date.formatted(.relative(presentation: .named)), height: 144,
                image: workspace.thumbnailLimit > 0
                  ? facts[visit.path]?.image ?? thumbnails[visit.path] : nil
              )
              .task(id: workspace.thumbnailLimit) {
                if imageFile(visit.path, extended: workspace.profiles.value.enabled(PreviewPlugins.moreImages, host: workspace.profile.id)) {
                  thumbnails[visit.path] = await smallImage(
                    visit.path, visit.stamp, workspace.readerPort.value, workspace.thumbnailLimit)
                }
              }
            }
          }
        }
      }
      section("Places", minimum: 250) {
        ForEach(
          ([workspace.homePath].compactMap { $0 }.map { Place(path: $0, directory: true) }
            + workspace.pinned)
        ) { place in
          Button {
            workspace.choosePlace(place)
          } label: {
            HStack {
              Glyph(
                place.path == workspace.homePath
                  ? "house" : place.directory == true ? "folder" : "doc")
              VStack(alignment: .leading) {
                Text(
                  place.path == workspace.homePath
                    ? "Home" : (place.path as NSString).lastPathComponent
                ).mobileFont(15, .semibold)
                Text(displayPath(place.path, home: workspace.homePath)).secondaryText().lineLimit(1)
              }
              Spacer()
            }.padding(12).card(12)
          }
        }
      }
    }
  }
  private func section<Content: View>(
    _ title: String, minimum: CGFloat, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).secondaryText().fontWeight(.semibold)
      LazyVGrid(
        columns: [
          GridItem(.adaptive(minimum: min(minimum, max(120, (width - 96) / 2))), spacing: 14)
        ], spacing: 12, content: content)
    }
  }
}

struct ContinueLine: View {
  let visit: Visit
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack {
        Glyph("doc.text")
        Text(visit.title).mobileFont(15, .semibold).lineLimit(1)
        if let heading = visit.position.heading {
          Text("· " + heading).secondaryText().lineLimit(1)
        }
        Spacer()
        Text("Continue").mobileFont(14, .semibold).foregroundStyle(HouseColor.paper)
          .padding(.horizontal, 16).frame(height: 34).background(HouseColor.ink, in: Capsule())
      }.padding(8).padding(.leading, 8).card(14)
    }
  }
}

struct CanvasCard: View {
  let title, excerpt, detail: String
  let height: CGFloat
  var image: CGImage?
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).mobileFont(17, .semibold).lineLimit(2)
        Text(excerpt).mobileFont(15).foregroundStyle(HouseColor.muted).lineLimit(
          height > 150 ? 5 : 3)
        Spacer(minLength: 4)
        Text(detail).secondaryText().lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 70)
      }
    }.padding(16).frame(height: height).card(12)
  }
}
