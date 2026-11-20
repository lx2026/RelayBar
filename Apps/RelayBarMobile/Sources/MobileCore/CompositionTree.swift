import Combine
import Composition
import CompositionUI
import Foundation
import HouseStyle
import PreviewSupport

package enum Profiles: ServiceKey { package typealias Value = PreferenceStore<Preferences> }
enum Trust: ServiceKey { typealias Value = PreferenceStore<[String: Identity]> }
package enum Keys: ServiceKey { package typealias Value = any KeyProvider }
package enum AuthenticationPort: ServiceKey { package typealias Value = SignIn }
enum Session: ServiceKey { typealias Value = any HostConnection }
package enum Files: ServiceKey { package typealias Value = any RemoteFiles }
package enum Readers: ServiceKey { package typealias Value = Reader }
enum Formats: ServiceKey { typealias Value = FilePreviewRegistry<ReadRequest, ReadDocument> }
package enum PaperSurface: ServiceKey { package typealias Value = HouseForm }
struct PaperFeature: Feature {
  @Offer(PaperSurface.self) var surface
  func run(_ context: FeatureContext) async throws {
    HousePalette.apply(.paper)
    surface.set(.paper)
    try context.effect("Paper appearance", cancel: { HousePalette.apply(.standard) }) {}
  }
}
package enum Demand: ServiceKey { package typealias Value = SceneDemand }
package enum Pages: ServiceKey { package typealias Value = Registry<PageKind> }
package enum Sections: ServiceKey { package typealias Value = Registry<HomeSection> }
package enum FileActions: ServiceKey { package typealias Value = Registry<FileAction> }
package enum Locations: ServiceKey { package typealias Value = Registry<LocationResolver> }

package enum Location: Equatable {
  case path(String)
  case host(String)
  case profile(Profile)
  case otherService(Profile, ServiceAddress)
  case service(ServiceAddress)
}
struct Provide<K: ServiceKey>: Feature {
  @Constant var value: K.Value
  @Offer<K> var port: Slot<K.Value>
  init(_ key: K.Type, _ value: K.Value) {
    _value = Constant(wrappedValue: value)
    _port = Offer(key)
  }
  func run(_ context: FeatureContext) async throws { port.set(value) }
}

package typealias ConnectionFactory =
  @MainActor (Profile, SignIn, any KeyProvider) -> any HostConnection

struct SessionFeature: Feature {
  let profile: Profile
  @Constant var states: HostStates
  @Constant var policy: TransferPolicy
  let attempt: Int
  @Constant var factory: ConnectionFactory
  @Need(Trust.self) var pins
  @Need(Profiles.self) var profiles
  @Need(Keys.self) var keys
  @Offer(WebUpstream.self) var upstream
  @Offer(Session.self) var connected
  @Offer(AuthenticationPort.self) var auth

  func run(_ context: FeatureContext) async throws {
    let preferences = profiles
    let signIn = SignIn(profile, pins, profiles: { preferences.value.hosts })
    let connection = factory(profile, signIn, keys)
    states.values[profile.id] = .connecting
    try context.effect(
      "Host status",
      cancel: {
        if case .failed = self.states.values[self.profile.id] { return }
        self.states.values[self.profile.id] = .idle
      }
    ) {}
    let (paths, sender) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let subscription = policy.changes.sink { sender.yield(()) }
    try context.effect(
      "Network path",
      cancel: {
        subscription.cancel()
        sender.finish()
      }
    ) {}
    try context.task("Check SSH on path change") {
      for await _ in paths {
        guard context.isActive, !Task.isCancelled else { return }
        await connection.networkPathChanged()
      }
    }
    auth.set(signIn)
    try context.task("SSH connection") {
      var routesAvailable = false
      await connection.run { state in
        guard context.isActive else { return }
        switch state {
        case .ready:
          if !routesAvailable, let opener = connection.routeOpener {
            self.upstream.set(opener)
            routesAvailable = true
          }
          self.states.values[self.profile.id] = .connected
          self.connected.set(connection)
          signIn.connected()
        case .lost, .connecting:
          self.connected.clear()
          self.states.values[self.profile.id] = .connecting
          signIn.update("Reconnecting…")
        case .failed(let message, let refused):
          self.upstream.clear()
          routesAvailable = false
          self.connected.clear()
          self.states.values[self.profile.id] = .failed(message)
          signIn.failed(message, passwordRefused: refused)
        }
      }
    }
    try context.effect("Host session", cancel: { signIn.cancel() }) { await connection.suspend() }
  }
}

struct FileFeature: Feature {
  let saver: Bool
  @Constant var policy: TransferPolicy
  let host: UUID
  @Constant var states: HostStates
  @Need(Session.self) var session
  @Need(AuthenticationPort.self) var signIn
  @Offer(SessionFiles.self) var files
  func run(_ context: FeatureContext) async throws {
    do {
      let service = try await session.files()
      try context.checkActive()
      if var adapter = service as? RemoteAdapter {
        let policy = policy
        let enabled = saver
        adapter.restrict = {
          await TransferPolicy.restrict(
            enabled: enabled, expensive: policy.costly, constrained: false)
        }
        files.set(adapter)
      } else {
        files.set(service)
      }
    } catch {
      if context.isActive {
        let message = error.localizedDescription
        states.values[host] = .failed(message)
        signIn.update(message)
      }
      throw error
    }
  }
}

let notebookPlugin = PluginDescriptor(
  id: "notebook-preview", title: "Notebook Preview",
  summary: "Read notebook cells and saved output.", symbol: "book", isOnByDefault: true,
  features: ["preview.notebook"], realmRelativeFeatures: ["preview.notebook"])
let tablePlugin = PluginDescriptor(
  id: "table-preview", title: "Table Preview", summary: "Read delimited files as tables.",
  symbol: "tablecells", isOnByDefault: true, features: ["preview.table"],
  realmRelativeFeatures: ["preview.table"])
package let scriptsPlugin = PluginDescriptor(
  id: "html-scripts", title: "HTML Scripts", summary: "Run scripts in HTML files.",
  symbol: "chevron.left.forwardslash.chevron.right", isOnByDefault: true,
  features: ["reader.scripts"], realmRelativeFeatures: ["reader.scripts"]
)
package enum HTMLScripts: ServiceKey { package typealias Value = Bool }
struct FormatFeature: Feature {
  var plainTables = false
  var formats: [Format] = [.markdown, .text, .json, .image, .html, .video]
  @Need(Formats.self) var registry
  func run(_ context: FeatureContext) async throws {
    for format in formats {
      var descriptor = format.descriptor
      if format == .text, plainTables {
        descriptor = PreviewDescriptor(
          id: descriptor.id, title: descriptor.title,
          extensions: descriptor.extensions.union(["csv", "tsv"]),
          maximumBytes: descriptor.maximumBytes)
      }
      try registry.register(descriptor, in: context) { request in
        try await PreviewResource(
          format.render(path: request.path, file: request.file, form: request.form))
      }
    }
  }
}

struct ReaderFeature: Feature {
  let profile: Profile
  @Constant var cache: DocumentCache
  @Need(Files.self) var files
  @Need(DocumentObservers.self) var observers
  @Need(Profiles.self) var preferences
  @Need(Trust.self) var pins
  @Need(Formats.self) var formats
  @Offer(Readers.self) var readers
  func run(_ context: FeatureContext) async throws {
    guard let identity = pins.value[profile.id.uuidString] else {
      throw CompositionError("Missing host identity.")
    }
    readers.set(
      .init(
        files: files, cache: cache, registry: formats, profile: profile, identity: identity,
        prefs: preferences,
        observers: observers, context: context))
  }
}

@MainActor package final class SceneDemand: ObservableObject {
  @Published var visible: [UUID: UUID] = [:]
  package func show(_ profile: UUID?, in scene: UUID) { visible[scene] = profile }
}

@MainActor package final class MobileComposition {
  private let policy = TransferPolicy()
  package let routes = WebRoutePool()
  package let states = HostStates()
  package let runtime = FeatureRuntime()
  private let basePages = Registry<PageKind>()
  private let baseSections = Registry<HomeSection>()
  private let baseLocations = Registry<LocationResolver>()
  private let baseActions = Registry<FileAction>()
  private let preferences: PreferenceStore<Preferences>
  private let pins: PreferenceStore<[String: Identity]>
  private let keys: any KeyProvider
  package let cache: DocumentCache
  private let demand = SceneDemand()
  private let searchDirectory: URL
  private let factory: ConnectionFactory
  private var attempts: [UUID: Int] = [:]
  package private(set) var treeError: String?
  private var subscriptions = Set<AnyCancellable>()
  nonisolated package static let plugins: [PluginDescriptor] = [
    notebookPlugin, tablePlugin, scriptsPlugin, pinsPlugin,
    .init(
      id: "favorites", title: "Pinned Places", summary: "Pin folders and files to Places.",
      symbol: "pin",
      isOnByDefault: true, realmRelativeFeatures: ["saved-files"]
    ),
    .init(
      id: "prompt-search", title: "Prompt Search", summary: "Search image prompts.",
      symbol: "magnifyingglass",
      isOnByDefault: true, realmRelativeFeatures: ["search-prompts"]),
    fileSearchPlugin, logPlugin, localhostPlugin, networkPlugin, labelsPlugin,
    .init(
      id: "data-saver", title: "Data Saver", summary: "Reduce remote data use.", symbol: "leaf",
      isOnByDefault: true, realmRelativeFeatures: ["thumbnail-budget"]),
    deletePlugin,
    .init(
      id: PaperAppearance.plugin.id, title: PaperAppearance.plugin.title,
      summary: "Use the warm paper colours of RelayBar and Frame.",
      symbol: PaperAppearance.plugin.symbol, isOnByDefault: true, features: ["paper-appearance"],
      realmRelativeFeatures: ["appearance.paper"]),
  ]

  package lazy var composer = PluginComposer(
    runtime: runtime, plugins: Self.plugins,
    globalChoice: { [preferences] in preferences.value.plugins.overrides[$0.id] },
    setEnabled: { [preferences] plugin, on in
      try preferences.update { $0.plugins.set(plugin, enabled: on) }
    },
    hostChoice: { [preferences] plugin, realm in
      guard let host = preferences.value.hosts.first(where: { $0.realm == realm }),
        let choice = preferences.value.hostPlugins?[host.id]?.overrides[plugin.id]
      else { return .inherit }
      return choice ? .on : .off
    },
    setHostChoice: { [preferences] plugin, realm, choice in
      guard let host = preferences.value.hosts.first(where: { $0.realm == realm }) else {
        throw CompositionError("This host is no longer saved.")
      }
      try preferences.update {
        $0.set(plugin, for: host.id, enabled: choice == .inherit ? nil : choice == .on)
      }
    })

  package init(
    directory: URL, cache: URL, keys: any KeyProvider = EnclaveKeys(),
    factory: @escaping ConnectionFactory = TransportConnection.init
  ) throws {
    preferences = PreferenceStore(
      url: directory.appendingPathComponent("preferences.json"), initial: Preferences()
    ) { value in
      guard Set(value.hosts.map(\.id)).count == value.hosts.count,
        value.hosts.allSatisfy({ !$0.host.isEmpty && !$0.account.isEmpty && $0.port > 0 })
      else {
        throw CompositionError("Invalid host profile in preferences.")
      }
    }
    pins = PreferenceStore(url: directory.appendingPathComponent("trust.json"), initial: [:])
    self.searchDirectory = cache.appending(path: "file-search")
    self.keys = keys
    self.cache = DocumentCache(directory: cache)
    self.factory = factory
    try preferences.load()
    if preferences.value.favourites != nil { try preferences.update { $0.migratePlaces() } }
    try pins.load()
    preferences.$value.combineLatest(pins.$value).map { prefs, identities in
      Set(
        prefs.hosts.flatMap { host -> [CacheIdentity] in
          guard let identity = identities[host.id.uuidString] else { return [] }
          let pins =
            prefs.enabled("pinned-services", host: host.id)
            ? prefs.pinnedServices?[host.id] ?? [] : []
          return (pins + (prefs.serviceTabs?[host.id] ?? [])).compactMap {
            Self.pictureKey($0, host, identity)
          }
        })
    }.removeDuplicates().sink { [cache = self.cache] keys in
      Task { try? await cache.keepWebsitePictures(keys) }
    }.store(in: &subscriptions)
    try rebuild(demand.visible)
    demand.$visible.dropFirst().sink { [weak self] visible in
      self?.refresh(visible)
    }.store(in: &subscriptions)
    preferences.$value.removeDuplicates {
      $0.plugins == $1.plugins && $0.hosts == $1.hosts && $0.hostPlugins == $1.hostPlugins
        && $0.pinnedPlaces == $1.pinnedPlaces && $0.homeFolders == $1.homeFolders
    }
    .dropFirst().sink { [weak self] next in
      guard let self else { return }
      refresh(demand.visible, preferences: next)
    }.store(in: &subscriptions)
  }

  private static func pictureKey(_ address: ServiceAddress, _ host: Profile, _ identity: Identity)
    -> CacheIdentity?
  {
    address.saved.url(host: host.host).map {
      CacheIdentity(
        profile: host.id, account: host.account, fingerprint: identity.fingerprint,
        path: $0.absoluteString)
    }
  }
  package func websiteKey(_ address: ServiceAddress, host: Profile) -> CacheIdentity? {
    pins.value[host.id.uuidString].flatMap { Self.pictureKey(address, host, $0) }
  }

  private func refresh(_ visible: [UUID: UUID], preferences: Preferences? = nil) {
    do {
      try rebuild(visible, choices: preferences)
      treeError = nil
    } catch { treeError = error.localizedDescription }
  }

  package func retry(_ host: UUID) throws {
    attempts[host, default: 0] += 1
    try rebuild(demand.visible)
  }

  private func rebuild(_ visible: [UUID: UUID], choices: Preferences? = nil) throws {
    let choices = choices ?? preferences.value
    let (preferences, pins, keys, demand, cache, factory, attempts) = (
      self.preferences, self.pins, self.keys, self.demand, self.cache, self.factory, self.attempts
    )
    let searchDirectory = self.searchDirectory
    NameIndex.prune(directory: searchDirectory, choices: choices)
    let hosts = choices.hosts.filter { visible.values.contains($0.id) }.map { profile in
      // Internet permission belongs to the HTML reader. Updating it must not restart SSH.
      var connection = profile
      connection.allowsInternetResources = false
      return connection
    }
    HousePalette.apply(PaperAppearance.form(choices.plugins))
    let (sections, locations, actions) = (baseSections, baseLocations, baseActions)
    let pages = basePages
    let states = states
    let policy = policy
    try runtime.set {
      if choices.plugins.isEnabled(PaperAppearance.plugin) {
        FeatureNode("paper-appearance") { PaperFeature() }
      }
      FeatureNode("profiles") { Provide(Profiles.self, preferences) }
      FeatureNode("trust") { Provide(Trust.self, pins) }
      FeatureNode("keys") { Provide(Keys.self, keys) }
      FeatureNode("scene-demand") { Provide(Demand.self, demand) }
      FeatureNode("preview-formats") { Provide(Formats.self, FilePreviewRegistry()) }
      FeatureNode("page-kinds") { Provide(Pages.self, pages) }
      FeatureNode("locations") { Provide(Locations.self, locations) }
      FeatureNode("start-sections") { Provide(Sections.self, sections) }
      FeatureNode("file-actions") { Provide(FileActions.self, actions) }
      FeatureNode("built-in-entries") { BuiltInEntries() }
      FeatureNode("formats") { FormatFeature(plainTables: !choices.plugins.isEnabled(tablePlugin)) }
      if choices.plugins.isEnabled(notebookPlugin) {
        FeatureNode("preview.notebook") { FormatFeature(formats: [.notebook]) }
      }
      if choices.plugins.isEnabled(tablePlugin) {
        FeatureNode("preview.table") { FormatFeature(formats: [.table]) }
      }
      if choices.plugins.isEnabled(scriptsPlugin) {
        FeatureNode("reader.scripts") { Provide(HTMLScripts.self, true) }
      }
      for host in hosts {
        FeatureNode.realm(
          host.realm,
          isolating: [
            PaperSurface.self, NetworkAccess.self, Pages.self, Formats.self, HTMLScripts.self,
            Session.self, SessionFiles.self, FileSearch.self, Files.self, Readers.self,
            AuthenticationPort.self, Sections.self,
            Locations.self, FileActions.self, ThumbnailLimit.self, DocumentObservers.self,
            WebRoutes.self, WebUpstream.self, PinnedServices.self, ServiceLabellers.self,
          ]
        ) {
          if choices.enabled(PaperAppearance.plugin, host: host.id) {
            FeatureNode("appearance.paper") { Provide(PaperSurface.self, HouseForm.paper) }
          }
          FeatureNode("pages") { Provide(Pages.self, Registry(parent: pages)) }
          FeatureNode("preview-formats") { Provide(Formats.self, FilePreviewRegistry()) }
          FeatureNode("formats") {
            FormatFeature(plainTables: !choices.enabled(tablePlugin, host: host.id))
          }
          if choices.enabled(notebookPlugin, host: host.id) {
            FeatureNode("preview.notebook") { FormatFeature(formats: [.notebook]) }
          }
          if choices.enabled(tablePlugin, host: host.id) {
            FeatureNode("preview.table") { FormatFeature(formats: [.table]) }
          }
          if choices.enabled(scriptsPlugin, host: host.id) {
            FeatureNode("reader.scripts") { Provide(HTMLScripts.self, true) }
          }
          if choices.enabled(deletePlugin, host: host.id) {
            FeatureNode("actions.remove") { DeleteFeature() }
          }
          if choices.enabled(logPlugin, host: host.id) {
            FeatureNode("pages.follow") { LogFeature() }
          }
          if choices.enabled(networkPlugin, host: host.id) {
            FeatureNode("routes.network") { NetworkFeature(profile: host) }
          }
          FeatureNode("web-routes") { Provide(WebRoutes.self, Registry()) }
          FeatureNode("service-labellers") { Provide(ServiceLabellers.self, Registry()) }
          FeatureNode("direct") { RouteFeature(route: .direct) }
          FeatureNode("private-name") { RouteFeature(route: .privateName) }
          FeatureNode("file-locations") { PathResolverFeature() }
          FeatureNode("service-locations") { ServiceResolvers(profile: host) }
          if choices.enabled(localhostPlugin, host: host.id) {
            FeatureNode("exact-localhost") { RouteFeature(route: .localhost) }
          }
          if choices.enabled(pinsPlugin, host: host.id) {
            FeatureNode("services.pins") { PinFeature(profile: host) }
          }
          if choices.enabled(labelsPlugin, host: host.id) {
            FeatureNode("services.titles") { TitleFeature() }
          }
          FeatureNode("document-observers") { Provide(DocumentObservers.self, Registry()) }
          FeatureNode("locations") { Provide(Locations.self, Registry(parent: locations)) }
          FeatureNode("start-sections") { Provide(Sections.self, Registry(parent: sections)) }
          FeatureNode("file-actions") { Provide(FileActions.self, Registry(parent: actions)) }
          if choices.enabled("favorites", host: host.id) {
            FeatureNode("saved-files") { FavouritesFeature(host: host.id) }
          }
          if choices.enabled("prompt-search", host: host.id) {
            FeatureNode("search-prompts") { PromptSearchFeature(host: host.id) }
          }
          if choices.enabled("data-saver", host: host.id) {
            FeatureNode("thumbnail-budget") { ThumbnailPolicyFeature(policy: policy) }
          }
          FeatureNode("session") {
            SessionFeature(
              profile: host, states: states, policy: policy, attempt: attempts[host.id, default: 0],
              factory: factory)
          }
          FeatureNode("files") {
            FileFeature(
              saver: choices.enabled("data-saver", host: host.id), policy: policy, host: host.id,
              states: states)
          }
          if choices.enabled(fileSearchPlugin, host: host.id) {
            FeatureNode("search.files") {
              SearchFilesFeature(
                profile: host, directory: searchDirectory, home: choices.homeFolders?[host.id],
                places: choices.places(for: host.id).filter { $0.directory == true }.map(\.path),
                deferred: choices.enabled("data-saver", host: host.id))
            }
          } else {
            FeatureNode("browse.files") { PlainFilesFeature() }
          }
          FeatureNode("readers") { ReaderFeature(profile: host, cache: cache) }
        }
      }
    }
  }
}

extension MobileComposition {
  package func savedDocument(_ path: String, profile: Profile) async throws -> ReadDocument? {
    guard let identity = pins.value[profile.id.uuidString],
      let visit = preferences.value.history.first(where: {
        $0.profile == profile.id && $0.path == path
      }),
      let formats = runtime.service(Formats.self),
      let entry = await cache.cached(
        .init(
          profile: profile.id, account: profile.account, fingerprint: identity.fingerprint,
          path: path))
    else { return nil }
    guard preferences.value.missingPlugin(kind: "document", path: path, host: profile.id) == nil
    else { return nil }
    let form: HouseForm =
      preferences.value.enabled(PaperAppearance.plugin, host: profile.id) ? .paper : .standard
    var doc: ReadDocument
    if let selected = runtime.service(Formats.self, realm: profile.realm) {
      let preview = try await selected.open(
        filename: path, bytes: Int64(entry.data.count),
        request: .init(path: path, file: entry, form: form))
      doc = preview.content
      await preview.close()
    } else {
      // With no live realm, use the saved host's effective format for the cached bytes.
      let ext = (path as NSString).pathExtension.lowercased()
      let kind: Format?
      if Format.table.descriptor.extensions.contains(ext) {
        kind = preferences.value.enabled(tablePlugin, host: profile.id) ? .table : .text
      } else if Format.notebook.descriptor.extensions.contains(ext) {
        kind = .notebook
      } else {
        kind = formats.descriptor(for: path).flatMap { Format(rawValue: $0.id) }
      }
      guard let kind, entry.data.count <= kind.descriptor.maximumBytes else { return nil }
      doc = try await kind.render(path: path, file: entry, form: form)
    }
    doc.position = visit.position
    return doc
  }
}
