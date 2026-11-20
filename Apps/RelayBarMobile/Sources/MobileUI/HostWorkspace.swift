import PreviewSupport
import Composition
import HouseStyle
import ImageIO
import MobileCore
import SwiftUI

struct Route: Hashable, Codable {
  private enum CodingKeys: String, CodingKey { case kind, path, plainTable }
  let kind: String
  let path: String
  var plainTable: Bool?
  var saved: Self {
    guard kind == "service" else { return self }
    guard var url = URLComponents(string: path), url.host != nil else {
      return .init(kind: "home", path: "")
    }
    url.user = nil
    url.password = nil
    url.query = nil
    url.fragment = nil
    return .init(kind: kind, path: url.string ?? "")
  }
  init(kind: String, path: String, plainTable: Bool? = nil) {
    self.kind = kind
    self.path = path
    self.plainTable = plainTable
  }
  init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    self = try Self(
      kind: fields.decode(String.self, forKey: .kind),
      path: fields.decode(String.self, forKey: .path),
      plainTable: fields.decodeIfPresent(Bool.self, forKey: .plainTable)
    ).saved
  }
  func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    let route = saved
    try fields.encode(route.kind, forKey: .kind)
    try fields.encode(route.path, forKey: .path)
    try fields.encodeIfPresent(plainTable, forKey: .plainTable)
  }
  static func recent(_ visit: Visit) -> Self {
    .init(kind: visit.pageKind ?? "document", path: visit.path, plainTable: visit.plainTable)
  }
  static func folder(_ path: String) -> Self { .init(kind: "folder", path: path) }
  static func document(_ path: String) -> Self { .init(kind: "document", path: path) }
}

@MainActor final class FolderMemory {
  var offsets: [String: CGFloat] = [:]
  var lists: [String: Bool] = [:]
  var changedOnly: [String: Bool] = [:]
}

struct HostWorkspace: View, WorkspaceViews {
  let core: MobileComposition
  @ObservedObject var appearance: ServicePort<HouseForm>
  @ObservedObject var thumbnailBudget: ServicePort<Int>
  let profile: Profile
  @ObservedObject var profiles: PreferenceStore<Preferences>
  let switchService: (Profile, Route) -> Void
  let resume: (Profile, String) -> Void
  let choose: (Profile) -> Void
  let add: (String) -> Void
  let settings: () -> Void
  let hosts: () -> Void
  @ObservedObject var files: ServicePort<any RemoteFiles>
  @ObservedObject var fileSearch: ServicePort<NameIndex>
  @ObservedObject var readerPort: ServicePort<Reader>
  @ObservedObject var states: HostStates
  @ObservedObject var pages: ServicePort<Registry<PageKind>>
  @ObservedObject var webRoutes: ServicePort<Registry<WebRoute>>
  @ObservedObject var sections: ServicePort<Registry<HomeSection>>
  @Environment(\.scenePhase) private var phase
  @StateObject private var servicePages = ServicePages()
  @State var stack: [Route]
  @Environment(\.horizontalSizeClass) private var sizeClass
  @SceneStorage private var savedPad: Data?
  @State private var pad = PadSelection()
  @State var searchFocus = 0
  @State var searchingReader = false
  @State var siblingPaths: [String] = []
  @State var folderMemory = FolderMemory()
  @State var revealedFolder: String?
  @SceneStorage private var leftAt: Double
  @State fileprivate var matches: [Location] = []
  @State private var allRecent = false
  @State fileprivate var go = false
  @State fileprivate var message = ""
  var homePath: String? { profiles.value.homeFolders?[profile.id] }
  var resolvers: [LocationResolver] {
    core.runtime.service(Locations.self, realm: profile.realm)?.entries ?? []
  }
  init(
    core: MobileComposition, profile: Profile, profiles: PreferenceStore<Preferences>,
    initialRoute: Route?, switchService: @escaping (Profile, Route) -> Void = { _, _ in },
    choose: @escaping (Profile) -> Void, resume: @escaping (Profile, String) -> Void,
    add: @escaping (String) -> Void, settings: @escaping () -> Void, hosts: @escaping () -> Void
  ) {
    _leftAt = SceneStorage(wrappedValue: 0, "workspace.left." + profile.id.uuidString)
    _savedPad = SceneStorage("workspace." + profile.id.uuidString)
    self.switchService = switchService
    appearance = core.runtime.port(PaperSurface.self, realm: profile.realm)
    thumbnailBudget = core.runtime.port(ThumbnailLimit.self, realm: profile.realm)
    self.core = core
    self.profile = profile
    self.profiles = profiles
    self.choose = choose
    self.resume = resume
    self.add = add
    self.settings = settings
    self.hosts = hosts
    _stack = State(initialValue: initialRoute.map { [$0] } ?? [])
    states = core.states
    files = core.runtime.port(Files.self, realm: profile.realm)
    fileSearch = core.runtime.port(FileSearch.self, realm: profile.realm)
    readerPort = core.runtime.port(Readers.self, realm: profile.realm)
    pages = core.runtime.port(Pages.self, realm: profile.realm)
    webRoutes = core.runtime.port(WebRoutes.self, realm: profile.realm)
    sections = core.runtime.port(Sections.self, realm: profile.realm)
  }
  var usesPadLayout: Bool {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    #else
      false
    #endif
  }
  var state: HostState { states.values[profile.id] ?? .connecting }
  var visits: [Visit] { profiles.value.history.filter { $0.profile == profile.id } }
  var pinned: [Place] { profiles.value.places(for: profile.id) }
  var canPin: Bool { profiles.value.enabled("favorites", host: profile.id) }
  func update(_ change: (inout Preferences) -> Void) {
    do { try profiles.update(change) } catch { message = error.localizedDescription }
  }
  func togglePin(_ place: Place) {
    update { $0.togglePin(place, host: profile.id) }
  }
  func pinButton(_ place: Place) -> some View {
    let saved = pinned.contains { $0.path == place.path }
    return IconButton(
      label: (saved ? "Unpin " : "Pin ") + (place.path as NSString).lastPathComponent,
      symbol: saved ? "pin.fill" : "pin", circle: false
    ) { togglePin(place) }
  }
  func choosePlace(_ place: Place?) {
    update { $0.select(place, host: profile.id) }
    go = false
    guard let path = place?.path ?? homePath else { return }
    if place?.directory == nil, place != nil {
      navigate(.path(path))
      return
    }
    push(place?.directory == false ? fresh(.document(path)) : .folder(path))
  }
  func showLocation() {
    if usesPadLayout {
      searchingReader = pad.primary != nil && pad.primary?.kind != "folder"
      searchFocus += 1
    } else {
      go = true
    }
  }
  func websiteTitle(_ address: ServiceAddress) -> String {
    address.destination ?? profiles.value.serviceTitles?[profile.id]?[address.port] ?? "Website"
  }
  var pictureRevision: Int { servicePages.revision }
  func websitePicture(_ address: ServiceAddress) async -> CGImage? {
    guard let key = core.websiteKey(address, host: profile),
      let bytes = try? await core.cache.websitePicture(key),
      let source = CGImageSourceCreateWithData(bytes as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
  func page(_ route: Route) -> some View {
    Group {
      if route.plainTable != true,
        let missing = profiles.value.missingPlugin(
          kind: route.kind, path: route.path, host: profile.id)
      {
        ContentUnavailableView(
          "Turn on " + missing.title, systemImage: missing.symbol,
          description: Text((route.path as NSString).lastPathComponent))
      } else if let registry = pages.value {
        Entries(registry: registry) { entries in
          entries.first { $0.id == route.kind }?.render(self, route.path)
        }
      }
    }
  }
  var body: some View {
    Group {
      if usesPadLayout {
        PadWorkspace(
          workspace: self, selection: $pad,
          pick: { route, beside in pad.select(fresh(route), beside: beside) },
          service: { address, beside in
            if let url = address.url(host: profile.host) {
              do {
                try profiles.update { $0.open(address, host: profile.id) }
                pad.select(.init(kind: "service", path: url.absoluteString), beside: beside)
              } catch { message = error.localizedDescription }
            }
          }
        ) {
          if let primary = pad.primary {
            page(primary).id(primary)
          } else {
            PadStart(workspace: self)
          }
        } secondary: {
          if let route = pad.beside { page(route).id(route) }
        }
        .overlay {
          if searchingReader {
            PageScroll {
              GoPage(
                workspace: self, fromHome: false, hosts: profiles.value.hosts,
                states: states.values,
                canvas: AnyView(EmptyView())
              ).padding(36)
            }.background(HouseColor.paper)
          }
        }
        .overlay(alignment: .bottomLeading) {
          if !message.isEmpty { Text(message).secondaryText().padding(8).card() }
        }
        .onAppear {
          if let bytes = savedPad,
            let saved = try? JSONDecoder().decode(PadSelection.self, from: bytes)
          {
            if PadSelection.restores(leftAt) { pad = saved }
          }
          if let route = stack.popLast() { pad.select(route, beside: false) }
        }
        .onChange(of: phase) {
          if phase == .background { leftAt = Date().timeIntervalSince1970 }
          if phase == .active && leftAt != 0 {
            if !PadSelection.restores(leftAt) { pad = PadSelection() }
            leftAt = 0
          }
        }
        .onDisappear { leftAt = Date().timeIntervalSince1970 }
        .onChange(of: pad.treeSelection) { searchingReader = false }
        .onChange(of: pad) { savedPad = try? JSONEncoder().encode(pad) }
      } else {
        NavigationStack(path: $stack) {
          page(.init(kind: "home", path: "")).navigationDestination(for: Route.self) {
            page($0).hideNavigation()
          }.hideNavigation()
        }.safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            if !message.isEmpty { Text(message).secondaryText().padding(6).card() }
            if !["service", "tabs"].contains(stack.last?.kind ?? "") {
              LocationBar(
                host: profile.host,
                location: stack.last.map {
                  $0.kind == "folder"
                    ? displayPath($0.path, home: homePath) : ($0.path as NSString).lastPathComponent
                } ?? "Open a path, port or host", state: state,
                back: stack.isEmpty ? nil : { stack.removeLast() }
              ) {
                if case .failed = state { hosts() } else { go = true }
              }
            }
          }
        }
      }
    }.overlay {
      if go {
        GoPage(
          workspace: self, fromHome: usesPadLayout ? pad.primary == nil : stack.isEmpty,
          hosts: profiles.value.hosts, states: states.values)
      }
    }
    #if os(iOS)
      .environment(\.hostHouseForm, appearance.value ?? .standard)
    #endif
    .onDisappear { servicePages.suspend() }
    .onChange(of: phase) { if phase != .active { servicePages.suspend() } }
    .task(id: files.generation) {
      guard let files = files.value else { return }
      do {
        let home = try await files.home()
        try Task.checkCancellation()
        if home != homePath {
          try profiles.update { value in
            var folders = value.homeFolders ?? [:]
            folders[profile.id] = home
            value.homeFolders = folders
          }
        }
        for place in profiles.value.pinnedPlaces?[profile.id] ?? [] where place.directory == nil {
          try Task.checkCancellation()
          if let stamp = try? await files.stat(place.path) {
            try Task.checkCancellation()
            update { value in
              if let index = value.pinnedPlaces?[profile.id]?.firstIndex(where: {
                $0.path == place.path
              }) {
                value.pinnedPlaces?[profile.id]?[index].directory = stamp.directory
              }
            }
          }
        }
      } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
  }
  func fresh(_ route: Route) -> Route {
    var selection = route
    if route.kind == "document",
      ["csv", "tsv"].contains((route.path as NSString).pathExtension.lowercased()),
      !profiles.value.enabled("table-preview", host: profile.id)
    {
      selection.plainTable = true
    }
    return selection
  }
  func push(_ route: Route) {
    searchingReader = false
    searchFocus = 0
    if usesPadLayout {
      pad.select(route, beside: false)
    } else {
      stack.append(route)
    }
  }
  private func back() {
    if usesPadLayout {
      if pad.previous.isEmpty { pad.primary = nil } else { pad.back() }
    } else if !stack.isEmpty {
      stack.removeLast()
    }
  }
  func home() -> AnyView {
    AnyView(
      PageScroll {
        VStack(alignment: .leading, spacing: 12) {
          Text("Home").mobileFont(32, .bold)
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
              Button(action: hosts) {
                HStack {
                  StatusMark(state: state)
                  Text(profile.host).mobileFont(20, .bold).dynamicTypeSize(
                    ...DynamicTypeSize.xxxLarge)
                  Glyph("chevron.down").font(.caption)
                }
              }.frame(minHeight: 44)
              Text("On your tailnet · " + state.label.lowercased()).secondaryText()
            }
            Spacer()
            IconButton(label: "Settings", symbol: "gearshape", action: settings)
          }.padding(.bottom, 6)
          if let registry = sections.value {
            Entries(registry: registry) { entries in
              ForEach(entries.sorted { $0.order < $1.order }) { section in section.render(self) }
            }
          }
        }.padding(.horizontal, 20)
      }.background(HouseColor.paper))
  }
  func continueReading() -> AnyView {
    AnyView(
      Group {
        if let visit = profiles.value.history.first,
          let owner = profiles.value.hosts.first(where: { $0.id == visit.profile }),
          owner.id != profile.id || !pinned.contains(where: { $0.path == visit.path })
        {
          VStack(alignment: .leading, spacing: 2) {
            Text("Continue reading").secondaryText().fontWeight(.semibold)
            Text(visit.title).mobileFont(24, .bold)
            Text(
              (visit.path as NSString).lastPathComponent + " · "
                + displayPath(
                  (visit.path as NSString).deletingLastPathComponent,
                  home: profiles.value.homeFolders?[owner.id])
            ).secondaryText()
            HStack(spacing: 6) {
              Glyph("clock")
              Text("Last read " + visit.date.formatted(.relative(presentation: .named)))
            }
            .mobileFont(13).padding(.vertical, 8)
            if let heading = visit.position.heading {
              Text("At " + heading).secondaryText().fontWeight(.semibold)
            }
            if let plugin = profiles.value.missingPlugin(
              kind: visit.pageKind ?? "document", path: visit.path, host: owner.id)
            {
              Text("Turn on " + plugin.title).secondaryText()
            }
            Text(visit.excerpt).mobileFont(15).foregroundStyle(HouseColor.muted).lineLimit(2)
            MainButton(title: "Continue") {
              if owner.id == profile.id {
                push(.recent(visit))
              } else {
                resume(owner, visit.path)
              }
            }.padding(.top, 10)
          }.padding(18).card(20)
        }
      })
  }
  func places() -> AnyView {
    AnyView(
      VStack(alignment: .leading, spacing: 6) {
        Text("Places").mobileFont(17, .semibold)
        PlaceRows(workspace: self).padding(.horizontal, 10).card()
        if pinned.isEmpty { Text("Pin a folder to keep it here.").secondaryText() }
      })
  }
  func recent() -> AnyView {
    let recent = visits.filter { visit in !pinned.contains { $0.path == visit.path } }.filter {
      $0.path != profiles.value.history.first?.path
        || $0.profile != profiles.value.history.first?.profile
    }
    return AnyView(
      Group {
        if !recent.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            Text("Recent").mobileFont(17, .semibold).padding(.top, 10)
            ForEach(recent.prefix(allRecent ? recent.count : 5), id: \.path) { visit in
              historyLine(visit)
            }
            if recent.count > 5 {
              Button(allRecent ? "Show Less" : "Show All") { allRecent.toggle() }.frame(
                minHeight: 44)
            }
          }
        }
      })
  }
  fileprivate func historyLine(_ visit: Visit) -> some View {
    HistoryLine(
      visit: visit, files: files.value, reader: readerPort.value, limit: thumbnailLimit, extendedImages: profiles.value.enabled(PreviewPlugins.moreImages, host: profile.id),
      order: profiles.value.folderOrder?[profile.id] ?? .modified,
      missing: profiles.value.missingPlugin(
        kind: visit.pageKind ?? "document", path: visit.path, host: profile.id)?.title
    ) {
      go = false
      push(.recent(visit))
    }
  }
  var thumbnailLimit: Int {
    thumbnailBudget.value ?? DocumentCache.thumbnailSourceLimit
  }
  var pins: [ServiceAddress] {
    guard core.runtime.service(PinnedServices.self, realm: profile.realm) == true else { return [] }
    return profiles.value.pinnedServices?[profile.id] ?? []
  }
  var serviceList: [ServiceAddress] {
    pins + (profiles.value.serviceTabs?[profile.id] ?? []).filter { !pins.contains($0) }
  }
  func services() -> AnyView {
    AnyView(
      VStack(alignment: .leading, spacing: 0) {
        Text("Websites").mobileFont(17, .semibold)
        ForEach(serviceList, id: \.self) { address in
          FileLine(
            icon: pins.contains(address) ? "pin" : "network",
            title: address.destination ?? profiles.value.serviceTitles?[profile.id]?[address.port]
              ?? "Website",
            subtitle: ":\(address.port)"
          ) { openService(address) }
        }
        if serviceList.isEmpty {
          Button("Open a website", action: showLocation).secondaryText().frame(minHeight: 44)
        }
      })
  }
  func openServices() -> AnyView {
    AnyView(
      OpenServices(
        hosts: profiles.value.hosts, data: profiles.value, states: states.values,
        current: profile.id, disconnect: hosts,
        preview: { owner, address in owner.id == profile.id ? servicePages.preview(address) : nil },
        done: back, new: { go = true },
        open: { host, address in
          if host.id == profile.id {
            openService(address)
          } else if let url = address.url(host: host.host) {
            switchService(host, .init(kind: "service", path: url.absoluteString))
          }
        },
        close: { host, address in
          do {
            try profiles.update { $0.serviceTabs?[host.id]?.removeAll { $0 == address } }
            if host.id == profile.id { servicePages.close(address) }
            if host.id == profile.id {
              func matches(_ route: Route?) -> Bool {
                guard let route, route.kind == "service" else { return false }
                return
                  (ServiceAddress.parse(route.path, profile: host, kind: "address")
                  ?? ServiceAddress.external(route.path, profile: host))?.saved
                  == address
              }
              if matches(pad.beside) { pad.beside = nil }
              if matches(pad.primary) { pad.primary = nil }
              pad.previous.removeAll { matches($0) }
              pad.forward.removeAll { matches($0) }
              stack.removeAll {
                $0.kind == "service"
                  && (ServiceAddress.parse($0.path, profile: host, kind: "address")
                    ?? ServiceAddress.external($0.path, profile: host))?.saved == address
              }
            }
          } catch { message = error.localizedDescription }
        }))
  }
  func browser(_ url: String) -> AnyView {
    guard
      let address = ServiceAddress.parse(url, profile: profile, kind: "address")
        ?? ServiceAddress.external(url, profile: profile),
      let registry = webRoutes.value
    else {
      return AnyView(Text("Waiting for website routes…"))
    }
    if let missing = profiles.value.missingPlugin(for: address, host: profile.id) {
      return AnyView(Text("Turn on " + missing.title))
    }
    return AnyView(
      Entries(registry: registry) { entries in
        ServicePage(
          core: core, profile: profile, address: address, routes: entries, visible: !go,
          browser: servicePages.page(address), prefs: profiles,
          upstream: core.runtime.port(WebUpstream.self, realm: profile.realm),
          redirect: openService,
          back: {
            if usesPadLayout {
              if pad.previous.isEmpty { pad.primary = nil } else { pad.back() }
            } else if !stack.isEmpty {
              stack.removeLast()
            }
          }, tabs: { push(.init(kind: "tabs", path: "")) }, go: { go = true })
      })
  }
  func openService(_ address: ServiceAddress) {
    guard let url = address.url(host: profile.host) else { return }
    do {
      try profiles.update { value in
        value.open(address, host: profile.id)
      }
      go = false
      push(.init(kind: "service", path: url.absoluteString))
    } catch { message = error.localizedDescription }
  }
  func folder(_ path: String) -> AnyView {
    AnyView(
      FolderScreen(
        workspace: self, path: path, homePath: homePath, files: files, reader: readerPort.value,
        limit: thumbnailLimit, history: visits,
        actions: core.runtime.service(FileActions.self, realm: profile.realm)
      ) { push(fresh($0)) })
  }
  func log(_ path: String) -> AnyView {
    AnyView(
      LogPage(path: path, files: files) { stamp in
        try profiles.update { prefs in
          prefs.record(.following(path, profile: profile.id, stamp: stamp))
        }
      })
  }
  func reader(_ path: String) -> AnyView {
    AnyView(
      ReaderScreen(
        path: path, profile: profile, core: core, profiles: profiles, reader: readerPort,
        scriptPort: core.runtime.port(HTMLScripts.self, realm: profile.realm),
        files: files, openFolder: { push(.folder($0)) }, orderedPaths: siblingPaths
      ).id(path))
  }
  var relativeFolder: String? {
    guard let route = usesPadLayout ? pad.primary : stack.last,
      ["folder", "document", "image", "log"].contains(route.kind)
    else { return homePath }
    return route.kind == "folder" ? route.path : (route.path as NSString).deletingLastPathComponent
  }
  func openLocation(_ input: String) {
    let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let entries = core.runtime.service(Locations.self, realm: profile.realm)?.entries ?? []
    let candidates = LocationResolver.candidates(
      query, resolvers: entries, hosts: profiles.value.hosts)
    guard candidates.count == 1, let only = candidates.first else {
      matches = candidates
      message =
        candidates.isEmpty
        ? (query.hasPrefix("http://")
          ? "Use HTTPS for a full destination name." : "Enter a path, port or host.") : ""
      go = true
      return
    }
    navigate(only)
  }
  func navigate(_ target: Location) {
    go = false
    matches = []
    Task {
      do {
        switch target {
        case .profile(let owner): choose(owner)
        case .otherService(let owner, let address):
          if let url = address.url(host: owner.host) {
            try profiles.update { value in
              value.open(address, host: owner.id)
            }
            switchService(owner, .init(kind: "service", path: url.absoluteString))
          }
        case .service(let address): openService(address)
        case .host(let name):
          if let existing = profiles.value.hosts.first(where: {
            $0.host == name || $0.account + "@" + $0.host == name
          }) {
            choose(existing)
          } else {
            add(name)
          }
        case .path(let value):
          guard let remote = files.value else {
            throw CompositionError("Wait for the connection, then retry.")
          }
          let path: String
          if value == "~" || value.hasPrefix("~/") {
            path = (try await remote.home() as NSString).appendingPathComponent(
              String(value.dropFirst(2)))
          } else if value.hasPrefix("/") {
            path = value
          } else {
            guard let parent = relativeFolder else {
              throw CompositionError("Waiting for the home folder.")
            }
            path = (parent as NSString).appendingPathComponent(value)
          }
          push(try await remote.stat(path).directory ? .folder(path) : fresh(.document(path)))
        }
        message = ""
      } catch { message = error.localizedDescription }
    }
  }
}

struct Entries<Entry: Identifiable, Content: View>: View {
  @ObservedObject var registry: Registry<Entry>
  @ViewBuilder let content: ([Entry]) -> Content
  var body: some View { content(registry.entries) }
}

struct GoPage: View {
  @Environment(\.renderingGallery) var snapshot
  let workspace: HostWorkspace
  let fromHome: Bool
  let hosts: [Profile]
  let states: [UUID: HostState]
  var canvas: AnyView?
  var heading: AnyView?
  var folderPath: String?
  private struct Request: Equatable {
    let query: String
    let generation: Int
    let searchGeneration: Int
  }
  @Environment(\.pageWidth) private var width
  @FocusState private var focus: Bool
  @State var query = ""
  @State var completions: [PathMatch] = []
  @State var hits: [NameHit] = []
  @State var searchStatus: String?
  var body: some View {
    let profile = workspace.profile
    let visits = workspace.visits
    let matches = workspace.matches
    let titles = workspace.profiles.value.serviceTitles?[profile.id] ?? [:]
    return Group {
      if let canvas {
        VStack(alignment: .leading, spacing: 18) {
          let headerLayout =
            width < 760 && heading != nil && query.isEmpty
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))
          headerLayout {
            if query.isEmpty, let heading {
              heading
              if width >= 760 { Spacer(minLength: 12) }
            }

            HStack {
              Glyph("magnifyingglass")
              TextField(
                heading != nil && query.isEmpty
                  ? "Search or go to" : "Find an article, folder or website", text: $query
              )
              .mobileField().mobileFont(17).focused($focus).onSubmit { submit() }
              Text("⌘K").secondaryText()
            }.padding(.horizontal, 16).frame(height: heading == nil || !query.isEmpty ? 56 : 38)
              .card(12)
              .frame(maxWidth: width >= 760 && heading != nil && query.isEmpty ? 320 : .infinity)
              .overlay {
                if !query.isEmpty {
                  RoundedRectangle(cornerRadius: 12).strokeBorder(MobileAccent.link)
                }
              }
            if query.isEmpty, workspace.canPin, let path = folderPath,
              path != workspace.homePath
            {
              workspace.pinButton(.init(path: path, directory: true))
            }
            if !query.isEmpty || workspace.searchingReader {
              Button("Cancel") {
                query = ""
                focus = false
                workspace.searchingReader = false
                workspace.searchFocus = 0
              }.foregroundStyle(MobileAccent.link)
            }
          }
          if query.isEmpty { canvas } else { canvasResults }
        }
        .onChange(of: workspace.searchFocus) { if workspace.searchFocus > 0 { focus = true } }
        .onAppear { if workspace.searchFocus > 0 { focus = true } }
      } else {
        PageScroll {
          VStack(alignment: .leading, spacing: 6) {
            Text("Go to").secondaryText()
            HStack {
              HStack {
                StatusMark(state: states[profile.id] ?? .idle)
                Text(profile.host).mobileFont(15, .semibold)
                Rectangle().fill(HouseColor.line).frame(width: 1, height: 20)
                Group {
                  if snapshot {
                    Text(query.isEmpty ? "Path, port or host" : query).foregroundStyle(
                      HouseColor.faint
                    )
                    .frame(
                      maxWidth: .infinity, alignment: .leading)
                  } else {
                    TextField("Path, port or host", text: $query).focused($focus).mobileField()
                      .onSubmit {
                        workspace.openLocation(query)
                      }
                  }
                }.mobileFont(16)
              }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 12).frame(
                minHeight: 50
              ).card(14)
                .overlay {
                  RoundedRectangle(cornerRadius: 14).strokeBorder(MobileAccent.link, lineWidth: 1.5)
                }
              Button("Cancel") { workspace.go = false }.frame(minHeight: 44).foregroundStyle(
                MobileAccent.link)
            }
            if query.isEmpty {
              HStack(spacing: 8) {
                Text("Try").secondaryText()
                ForEach(
                  ["~/runs", ":6006", "user@host"].filter { example in
                    workspace.resolvers.contains { $0.resolve(example) != nil }
                  }, id: \.self
                ) {
                  example in
                  Button {
                    query = example
                  } label: {
                    Text(example).font(.footnote.monospaced()).padding(8).background(
                      HouseColor.fill, in: RoundedRectangle(cornerRadius: 8))
                  }.frame(minHeight: 44)
                }
              }
            }
            LazyVStack(spacing: 0) {
              ForEach(completions) { match in
                HStack {
                  FileLine(
                    icon: match.place.directory == true ? "folder" : "doc",
                    title: (match.place.path as NSString).lastPathComponent, subtitle: ""
                  ) {
                    if match.place.directory == true {
                      query = match.input
                    } else {
                      workspace.go = false
                      workspace.push(workspace.fresh(.document(match.place.path)))
                    }
                  }
                  if match.place.directory == true, workspace.canPin {
                    workspace.pinButton(match.place)
                  }
                }
              }
            }
            if !workspace.message.isEmpty { Text(workspace.message).secondaryText() }
            if !matches.isEmpty {
              Text("Choose a match").secondaryText()
              ForEach(matches.indices, id: \.self) { index in
                Button {
                  workspace.navigate(matches[index])
                } label: {
                  switch matches[index] {
                  case .profile(let host): Text("Host · " + host.account + "@" + host.host)
                  case .otherService(let host, let address):
                    Text(host.account + "@" + host.host + ":" + String(address.port))
                  case .host(let name): Text("Host · " + name)
                  case .path(let path): Text("File · " + path)
                  case .service(let address): Text(verbatim: "Website · :" + String(address.port))
                  }
                }.frame(minHeight: 44)
              }
            }
            if !fromHome && query.isEmpty {
              workspace.places()
            }
            if !hits.isEmpty { Text("Files").secondaryText().padding(.top, 12) }
            ForEach(hits) { hit in
              HStack {
                FileLine(
                  icon: hit.place.directory == true ? "folder" : "doc",
                  title: (hit.place.path as NSString).lastPathComponent, subtitle: hit.subtitle
                ) {
                  workspace.go = false
                  workspace.push(
                    workspace.fresh(
                      hit.place.directory == true ? .folder(hit.id) : .document(hit.id)))
                }
                if hit.place.directory == true, workspace.canPin { workspace.pinButton(hit.place) }
              }
            }
            if let searchStatus { Text(searchStatus).secondaryText() }
            let matchingServices = workspace.serviceList.filter {
              query.isEmpty || String($0.port).contains(query)
                || titles[$0.port]?.localizedCaseInsensitiveContains(query) == true
            }
            if !fromHome && !matchingServices.isEmpty {
              Text("Websites").secondaryText().padding(.top, 12)
              ForEach(matchingServices, id: \.self) { pin in
                FileLine(
                  icon: "network", title: ":\(pin.port)", subtitle: titles[pin.port] ?? "Website"
                ) { workspace.openService(pin) }
              }
            }
            let matchingVisits = visits.filter {
              query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)
            }
            if !fromHome && !matchingVisits.isEmpty {
              Text("Recent").secondaryText().padding(.top, 12)
              ForEach(matchingVisits, id: \.path) { visit in
                workspace.historyLine(visit)
              }
            }
            let matchingHosts = hosts.filter {
              query.isEmpty || $0.host.localizedCaseInsensitiveContains(query)
            }
            if !matchingHosts.isEmpty { Text("Hosts").secondaryText().padding(.top, 12) }
            ForEach(matchingHosts) {
              host in
              HostRow(
                profile: host, state: states[host.id] ?? .idle,
                lastVisit: workspace.profiles.value.history.first { $0.profile == host.id }
              ) { workspace.navigate(.profile(host)) }
            }
          }.padding(.horizontal, 20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(HouseColor.paper).onAppear {
          focus = true
        }
      }
    }.onChange(of: query) {
      completions = []
      hits = []
      searchStatus = nil
      workspace.matches = []
      workspace.message = ""
    }
    .task(
      id: Request(
        query: query, generation: workspace.files.generation,
        searchGeneration: workspace.fileSearch.generation)
    ) {
      guard !snapshot else { return }
      let input = query
      hits = []
      searchStatus = nil
      completions = []
      guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      await withTaskGroup(of: Void.self) { group in
        for source in LocationResultSource.sources(search: workspace.fileSearch.value) {
          group.addTask { await refresh(source, input: input) }
        }
      }
    }
  }

  private struct Choice: Identifiable {
    let group, title, detail, icon: String
    let target: Location
    var route: Route? = nil
    var key: String? = nil
    var id: String { group + (key ?? detail + title) }
  }
  private var choices: [Choice] {
    var items: [Choice] = []
    var paths: Set<String> = []
    func add(_ path: String, title: String, folder: Bool) {
      guard paths.insert(path).inserted else { return }
      items.append(
        Choice(
          group: folder ? "Folders" : "Articles", title: title,
          // The row's title already names the item, so the detail says only where it lives.
          detail: displayPath(
            (path as NSString).deletingLastPathComponent, home: workspace.homePath),
          icon: folder ? "folder" : "doc.text",
          target: .path(path),
          route: folder
            ? .folder(path)
            : workspace.visits.first { $0.path == path }.map(Route.recent)
              ?? workspace.fresh(.document(path)), key: path))
    }
    for hit in hits {
      add(
        hit.id,
        title: workspace.visits.first { $0.path == hit.id }?.title
          ?? (hit.id as NSString).lastPathComponent,
        folder: hit.place.directory == true)
    }
    for visit in workspace.visits
    where visit.title.localizedStandardContains(query)
      || visit.path.localizedStandardContains(query)
    {
      add(visit.path, title: visit.title, folder: false)
    }
    for pin in workspace.pinned where pin.path.localizedStandardContains(query) {
      add(pin.path, title: (pin.path as NSString).lastPathComponent, folder: pin.directory == true)
    }
    for site in workspace.serviceList
    where workspace.websiteTitle(site).localizedStandardContains(query)
      || ":\(site.port)".contains(query)
    {
      items.append(
        Choice(
          group: "Websites", title: workspace.websiteTitle(site), detail: ":\(site.port)",
          icon: "globe", target: .service(site)))
    }
    for host in hosts where host.host.localizedStandardContains(query) {
      items.append(
        Choice(
          group: "Hosts", title: host.host, detail: host.account, icon: "desktopcomputer",
          target: .profile(host)))
    }
    if query.contains("/") {
      for item in completions {
        items.append(
          Choice(
            group: "Paths", title: item.input, detail: "",
            icon: item.place.directory == true ? "folder" : "doc", target: .path(item.place.path)))
      }
    }
    // An exact website name, or a prefix of one of its words, opens directly on Return.
    if let index = items.firstIndex(where: {
      $0.group == "Websites"
        && $0.title.split(separator: " ").contains { $0.lowercased().hasPrefix(query.lowercased()) }
    }) {
      items.insert(items.remove(at: index), at: 0)
    }
    return items
  }
  private func activate(_ choice: Choice) {
    if choice.group == "Paths", case .path(let path) = choice.target,
      let match = completions.first(where: { $0.place.path == path }), match.place.directory == true
    {
      query = match.input
    } else {
      let target = choice.target
      query = ""
      focus = false
      if let route = choice.route { workspace.push(route) } else { workspace.navigate(target) }
    }
  }
  private func submit() {
    if let first = choices.first {
      if first.group == "Paths" { workspace.navigate(first.target) } else { activate(first) }
    } else {
      workspace.openLocation(query)
    }
  }
  private var canvasResults: some View {
    let items = choices
    return VStack(alignment: .leading, spacing: 8) {
      ForEach(["Top hit", "Articles", "Websites", "Folders", "Hosts", "Paths"], id: \.self) {
        group in
        let rows =
          group == "Top hit"
          ? Array(items.prefix(1)) : items.dropFirst().filter { $0.group == group }
        if !rows.isEmpty {
          Text(group).secondaryText().padding(.top, 10)
          ForEach(rows) { row in
            Button {
              activate(row)
            } label: {
              HStack {
                Glyph(row.icon)
                Text(row.title).mobileFont(16)
                Spacer()
                Text(group == "Top hit" ? "Return to open" : row.detail).secondaryText().lineLimit(
                  1)
              }.padding(.horizontal, 12).frame(minHeight: 46)
                .background(
                  group == "Top hit" ? HouseColor.fill : Color.clear,
                  in: RoundedRectangle(cornerRadius: 10))
            }
            Hairline()
          }
        }
      }
      if let searchStatus { Text(searchStatus).secondaryText() }
      Text("Type a name, a path such as ~/notes or a port such as :8888.").secondaryText()
    }.frame(maxWidth: 760, alignment: .leading)
  }

  private func refresh(_ source: LocationResultSource, input: String) async {
    do {
      switch source {
      case .paths(let complete):
        if canvas != nil && !input.contains("/") { return }
        guard let files = workspace.files.value else { return }
        let found = try await complete(input, workspace.relativeFolder, files)
        try Task.checkCancellation()
        if input == query { completions = found }
      case .files(let index):
        guard !input.hasPrefix("/"), !input.hasPrefix("~/"), !input.contains("://"),
          !input.hasPrefix(":"), !input.hasPrefix("prompt:")
        else { return }
        var revision: Int?
        repeat {
          if let result = await index.results(input, visits: workspace.visits, since: revision) {
            try Task.checkCancellation()
            guard input == query else { return }
            (revision, hits, searchStatus) = result
          }
          try await Task.sleep(for: .milliseconds(600))
        } while !Task.isCancelled
      }
    } catch {}
  }
}

struct PlaceRows: View {
  let workspace: HostWorkspace
  var body: some View {
    let pinned = workspace.pinned
    VStack(alignment: .leading, spacing: 0) {
      row(nil, rule: !pinned.isEmpty)
      ForEach(Array(pinned.enumerated()), id: \.element.id) { index, place in
        row(place, rule: index + 1 < pinned.count).contextMenu {
          ForEach([-1, 1], id: \.self) { offset in
            if pinned.indices.contains(index + offset) {
              Button(offset < 0 ? "Move Up" : "Move Down") {
                workspace.update { value in
                  guard let places = value.pinnedPlaces?[workspace.profile.id],
                    let position = places.firstIndex(where: { $0.path == place.path }),
                    places.indices.contains(position + offset)
                  else { return }
                  value.pinnedPlaces?[workspace.profile.id]?.swapAt(position, position + offset)
                }
              }
            }
          }
          Button("Unpin") { workspace.togglePin(place) }
        }
      }
    }
  }
  @ViewBuilder private func row(_ place: Place?, rule: Bool) -> some View {
    let title = place.map { ($0.path as NSString).lastPathComponent } ?? "Home"
    let icon = place == nil ? "house" : place?.directory == true ? "folder" : "doc"
    FileLine(
      icon: icon, title: title,
      subtitle: place.map { displayPath($0.path, home: workspace.homePath) } ?? "~",
      chevron: true, rule: rule
    ) { workspace.choosePlace(place) }
  }
}
