import AppKit
import BridgeProtocol
import Combine
import Composition
import CompositionUI
import HouseStyle
import PreviewSupport

/// The services RelayBar's features exchange. A key is a type, so a feature can only name what exists.
enum RelayServices {
    enum Tunnels: ServiceKey { typealias Value = TunnelStore }
    enum Updates: ServiceKey { typealias Value = UpdateModel }
    enum UpdateService: ServiceKey { typealias Value = any UpdateServicing }
    enum Login: ServiceKey { typealias Value = LaunchAtLoginModel }
    enum FrameHost: ServiceKey { typealias Value = FrameBridgeBroker }
    enum RemoteFiles: ServiceKey { typealias Value = RemoteFilesModel }
    enum RemoteWindow: ServiceKey { typealias Value = RemoteFilesWindowController }
    enum PreviewRegistry: ServiceKey { typealias Value = RemotePreviewPlugins.Registry }
    enum PreviewReader: ServiceKey { typealias Value = any RemoteFileServing }
    enum PreviewDecoders: ServiceKey { typealias Value = RelayPreviewDecoders }
    enum ServiceLabels: ServiceKey { typealias Value = ServiceLabelBoard }
}

/// Values the composition root hands to features: stores that never unload, factories, and test doubles.
@MainActor
final class RelayBarEnvironment {
    let defaults: UserDefaults
    let catalog: RemoteServerCatalog
    let makeTunnels: @MainActor () -> TunnelStore
    let makeFileService: () -> any RemoteFileServing
    let makeUpdates: @MainActor (TunnelStore) -> any UpdateServicing
    let loginService: any LoginItemServicing
    let showsWindows: Bool
    let recoveryEvents: any RecoveryEvents
    let recoveryDebounce: Duration
    let serviceProbe: any ServiceProbing
    /// Where the Frame bridge puts its socket: the shared app-group container, or a test's own folder.
    let bridgeRoot: () throws -> URL

    init(defaults: UserDefaults, catalog: RemoteServerCatalog, makeTunnels: @escaping @MainActor () -> TunnelStore,
         makeFileService: @escaping () -> any RemoteFileServing,
         makeUpdates: @escaping @MainActor (TunnelStore) -> any UpdateServicing,
         loginService: any LoginItemServicing, showsWindows: Bool,
         recoveryEvents: any RecoveryEvents, recoveryDebounce: Duration, serviceProbe: any ServiceProbing,
         bridgeRoot: @escaping () throws -> URL) {
        self.defaults = defaults; self.catalog = catalog; self.makeTunnels = makeTunnels
        self.makeFileService = makeFileService; self.makeUpdates = makeUpdates
        self.loginService = loginService; self.showsWindows = showsWindows
        self.recoveryEvents = recoveryEvents
        self.recoveryDebounce = recoveryDebounce
        self.serviceProbe = serviceProbe; self.bridgeRoot = bridgeRoot
    }
}

// MARK: - Features

/// Owns the tunnel store. Each profile's processes belong to the store's own scopes.
struct TunnelsFeature: Feature {
    @Constant var environment: RelayBarEnvironment
    @Offer(RelayServices.Tunnels.self) var tunnels

    func run(_ context: FeatureContext) async throws {
        let store = environment.makeTunnels()
        try context.effect("tunnels", cancel: { store.closeAdmission() }) { await store.shutdown() }
        tunnels.set(store)
    }
}

/// The retry limit is this feature's configuration, so a committed change reloads it and nothing else.
struct RetryLimitSetting: Feature {
    let limit: Int
    @Need(RelayServices.Tunnels.self) var tunnels

    func run(_ context: FeatureContext) async throws { tunnels.setMaxRetryAttempts(limit) }
}

struct UpdatesFeature: Feature {
    @Constant var environment: RelayBarEnvironment
    @Need(RelayServices.Tunnels.self) var tunnels
    @Offer(RelayServices.Updates.self) var updates
    @Offer(RelayServices.UpdateService.self) var service

    func run(_ context: FeatureContext) async throws {
        let service = environment.makeUpdates(tunnels)
        let model = UpdateModel(service: service, available: { [weak context] in context?.isActive == true })
        service.start()
        try context.effect("updater") { await model.stop() }
        updates.set(model)
        self.service.set(service)
    }
}

struct AutomaticUpdateSetting: Feature {
    let enabled: Bool
    @Need(RelayServices.Updates.self) var updates

    func run(_ context: FeatureContext) async throws { updates.setAutomaticallyChecksForUpdates(enabled) }
}

struct LoginFeature: Feature {
    @Constant var environment: RelayBarEnvironment
    @Offer(RelayServices.Login.self) var login

    func run(_ context: FeatureContext) async throws {
        let model = LaunchAtLoginModel(service: environment.loginService,
                                       available: { [weak context] in context?.isActive == true })
        try context.effect("login item", cancel: { model.stop() }) {}
        login.set(model)
    }
}

/// Remote-file authority for Frame. Discovery and cold launch work before Frame has a session.
struct FrameHostFeature: Feature {
    @Constant var environment: RelayBarEnvironment
    @Need(RelayServices.Tunnels.self) var tunnels
    @Offer(RelayServices.FrameHost.self) var host

    func run(_ context: FeatureContext) async throws {
        let store = tunnels
        let broker = FrameBridgeBroker(catalog: environment.catalog, defaults: environment.defaults, tunnels: { [weak context] in
            context?.isActive == true ? store.tunnels : []
        }, available: { [weak context] in context?.isActive == true }, socketRoot: environment.bridgeRoot)
        broker.start()
        try context.effect("frame bridge", cancel: { broker.stop() }) { await broker.shutdown() }
        host.set(broker)
    }
}

/// Present while the Remote Files window is open. Its children are the enabled preview formats.
struct RemoteFilesWindowFeature: Feature {
    @Constant var environment: RelayBarEnvironment
    @Constant var onClose: @MainActor () -> Void
    @Need(RelayServices.Tunnels.self) var tunnels
    @Offer(RelayServices.RemoteWindow.self) var window
    @Offer(RelayServices.RemoteFiles.self) var files
    @Offer(RelayServices.PreviewRegistry.self) var registry
    @Offer(RelayServices.PreviewReader.self) var reader
    @Offer(RelayServices.PreviewDecoders.self) var decoders

    func run(_ context: FeatureContext) async throws {
        let service = environment.makeFileService(), previewRegistry = RemotePreviewPlugins.Registry()
        let previews = RemotePreviews(registry: previewRegistry, ready: { [weak context] in
            guard let context else { throw CancellationError() }
            try context.checkActive()
        }, stop: {}) // The parent runtime owns registrations and awaits their disposal.
        let model = RemoteFilesModel(tunnels: tunnels.tunnels, service: service,
                                     serverCatalog: environment.catalog, previews: previews)
        let windows = RemoteFilesWindowController()
        let observation = tunnels.$tunnels.sink { [weak model] in model?.updateTunnels($0) }
        windows.onClose = onClose
        try context.effect("remote files window") {
            observation.cancel(); windows.onClose = nil
            windows.close()
            await model.shutdown()
        }
        window.set(windows); files.set(model); registry.set(previewRegistry)
        reader.set(service); decoders.set(model.previewDecoders)
        if environment.showsWindows { windows.show(model: model) }
    }
}

/// Connects the open window to the Frame host. The window shows Open in Frame only while this runs.
struct OpenInFrameFeature: Feature {
    @Need(RelayServices.RemoteFiles.self) var files
    @Need(RelayServices.FrameHost.self) var host

    func run(_ context: FeatureContext) async throws {
        let files = files, host = host
        files.frameViewer = { [weak context] server, path, focus in
            guard let context else { throw CancellationError() }
            try context.checkActive()
            host.openInFrame(server: server, path: path, focus: focus)
        }
        try context.effect("open in frame") { files.frameViewer = nil }
    }
}

// MARK: - Composition root

@MainActor
final class RelayBarComposition: ObservableObject {
    @Published var errorMessage: String?
    let runtime = FeatureRuntime()
    let preferences: PreferenceStore<RelayBarPreferences>
    let environment: RelayBarEnvironment
    private let startsBridge: Bool
    private var remoteFilesOpen = false
    private var additionalFeatures: [FeatureNode]
    private var stopping = false
    private var reported: Set<String> = []
    private var observations: Set<AnyCancellable> = []
    private var storeObservation: AnyCancellable?
    private var labelsObservation: AnyCancellable?
    private let unavailableUpdates = UpdateModel(service: UnavailableUpdateService())
    /// Made the first time the Plugins window is shown; closed and released when the app stops.
    private(set) var pluginsWindow: RelayPluginsWindowController?
    /// Made the first time Settings opens; closed and released when the app stops.
    private(set) var settingsWindow: RelaySettingsWindowController?
    /// The catalog as decided at launch, when Open in Frame's default was set from whether Frame was installed.
    let plugins: [PluginDescriptor]
    let framePlugin: PluginDescriptor

    private let tunnelsPort: ServicePort<TunnelStore>
    private let loginPort: ServicePort<LaunchAtLoginModel>
    private let updatesPort: ServicePort<UpdateModel>
    private let windowPort: ServicePort<RemoteFilesWindowController>
    private let labelsPort: ServicePort<ServiceLabelBoard>
    private let hostPort: ServicePort<FrameBridgeBroker>

    var store: TunnelStore? { tunnelsPort.value }
    var login: LaunchAtLoginModel? { loginPort.value }
    var updates: UpdateModel { updatesPort.value ?? unavailableUpdates }
    var windows: RemoteFilesWindowController? { windowPort.value }
    /// Present while Service Labels runs.
    var serviceLabels: ServiceLabelBoard? { labelsPort.value }
    /// Present while Open in Frame runs and the bridge is listening.
    var frameHost: FrameBridgeBroker? { hostPort.value }

    init(defaults: UserDefaults = .standard, preferencesURL: URL? = nil,
         startsBridge: Bool = true, showsWindows: Bool = true,
         makeCatalog: @MainActor () -> RemoteServerCatalog = RemoteServerCatalog.appDefault,
         makeTunnels: (@MainActor () -> TunnelStore)? = nil,
         makeFileService: @escaping () -> any RemoteFileServing = { SFTPRemoteFileService() },
         makeUpdates: @escaping @MainActor (TunnelStore) -> any UpdateServicing = UpdateServiceFactory.make,
         loginService: any LoginItemServicing = MainAppLoginItemService(),
         browser: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         recoveryEvents: any RecoveryEvents = SystemRecoveryEvents(),
         recoveryDebounce: Duration = .seconds(2),
         serviceProbe: any ServiceProbing = HTTPServiceProbe(),
         frameInstalled: Bool = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FrameBridgeEnvironment.frameBundle) != nil,
         bridgeRoot: @escaping () throws -> URL = FrameBridgeEnvironment.root,
         additionalFeatures: [FeatureNode] = []) {
        environment = RelayBarEnvironment(defaults: defaults, catalog: makeCatalog(), makeTunnels: makeTunnels ?? {
            TunnelStore(defaults: defaults, browserOpener: browser, persistsRetryLimit: false)
        }, makeFileService: makeFileService, makeUpdates: makeUpdates, loginService: loginService, showsWindows: showsWindows,
           recoveryEvents: recoveryEvents, recoveryDebounce: recoveryDebounce, serviceProbe: serviceProbe,
           bridgeRoot: bridgeRoot)
        preferences = PreferenceStore(url: preferencesURL, initial: RelayBarPreferences()) { try $0.validate() }
        self.startsBridge = startsBridge
        self.additionalFeatures = additionalFeatures
        plugins = RelayPlugins.all(frameInstalled: frameInstalled)
        framePlugin = RelayPlugins.frame(installed: frameInstalled)
        tunnelsPort = runtime.port(RelayServices.Tunnels.self)
        loginPort = runtime.port(RelayServices.Login.self)
        updatesPort = runtime.port(RelayServices.Updates.self)
        windowPort = runtime.port(RelayServices.RemoteWindow.self)
        labelsPort = runtime.port(RelayServices.ServiceLabels.self)
        hostPort = runtime.port(RelayServices.FrameHost.self)

        // Views observe this object; it republishes when a service appears, changes or disappears.
        tunnelsPort.$value.sink { [weak self] store in
            self?.storeObservation = store?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            self?.objectWillChange.send()
        }.store(in: &observations)
        labelsPort.$value.sink { [weak self] board in
            self?.labelsObservation = board?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            self?.objectWillChange.send()
        }.store(in: &observations)
        for change in [loginPort.objectWillChange, updatesPort.objectWillChange, windowPort.objectWillChange,
                       hostPort.objectWillChange, preferences.objectWillChange] {
            change.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        runtime.$statuses.sink { [weak self] statuses in self?.statusesChanged(statuses) }.store(in: &observations)
        // Paper Appearance is drawn by the shell, not run as a feature: the saved choice applies before the first
        // window, and each later choice applies at once.
        let saved = preferences.peek()?.plugins ?? preferences.value.plugins
        HousePalette.apply(PaperAppearance.form(saved))
        preferences.$value.dropFirst().map { PaperAppearance.form($0.plugins) }.removeDuplicates()
            .sink { HousePalette.apply($0) }.store(in: &observations)
    }

    /// The whole tree, decided in one place from what the user chose and what is open.
    @FeatureTreeBuilder
    private func tree() -> [FeatureNode] {
        let environment = environment, chosen = preferences.value, close: @MainActor () -> Void = { [weak self] in
            self?.closeRemoteFiles()
        }
        let frame = chosen.plugins.isEnabled(framePlugin)
        FeatureNode("tunnels") { TunnelsFeature(environment: environment) }
        FeatureNode("tunnels.retry-limit") { RetryLimitSetting(limit: chosen.retryLimit) }
        if chosen.plugins.isEnabled(RelayPlugins.recovery) {
            FeatureNode("recovery") {
                RecoveryFeature(debounce: environment.recoveryDebounce, events: environment.recoveryEvents)
            }
        }
        if chosen.plugins.isEnabled(RelayPlugins.services) {
            FeatureNode("services") { ServiceLabelsFeature(probe: environment.serviceProbe) }
        }
        FeatureNode("updates") { UpdatesFeature(environment: environment) }
        FeatureNode("updates.schedule") { AutomaticUpdateSetting(enabled: chosen.automaticallyChecksForUpdates) }
        FeatureNode("login") { LoginFeature(environment: environment) }
        if startsBridge && frame { FeatureNode("frame.host") { FrameHostFeature(environment: environment) } }
        if remoteFilesOpen {
            FeatureNode("remote.files") { RemoteFilesWindowFeature(environment: environment, onClose: close) } children: {
                for descriptor in RemotePreviewPlugins.descriptors where chosen.preview(descriptor.id).enabled {
                    FeatureNode("preview.\(descriptor.id)") {
                        RemotePreviewFormat(kind: descriptor.id, maximumBytes: chosen.preview(descriptor.id).maximumBytes)
                    }
                }
                if frame { FeatureNode("open-in-frame") { OpenInFrameFeature() } }
            }
        }
        additionalFeatures
    }

    private func apply() async throws {
        try runtime.set(tree())
        await runtime.settled()
    }

    func start() async {
        stopping = false; errorMessage = nil; reported = []
        do {
            let defaults = environment.defaults
            try preferences.load(importing: { RelayBarPreferences.legacy(defaults) })
            try await apply()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Unloads every feature. Never waits past the deadline; whatever did not finish is reported.
    func stop() async {
        stopping = true
        remoteFilesOpen = false
        pluginsWindow?.close()
        pluginsWindow = nil
        settingsWindow?.close()
        settingsWindow = nil
        let unfinished = await runtime.shutdown(deadline: .seconds(20))
        for status in unfinished { NSLog("RelayBar: %@ did not finish unloading: %@", status.id, "\(status.phase)") }
    }

    private func statusesChanged(_ statuses: [FeatureStatus]) {
        updates.refresh()
        // A feature that failed or is stuck is told to the user once, with its reason.
        for status in statuses {
            let reason: String
            switch status.phase {
            case .failed(let message): reason = message
            case .stuck(let message): reason = message
            default: reported.remove(status.id); continue
            }
            if reported.insert(status.id).inserted, !stopping { errorMessage = "\(status.id): \(reason)" }
        }
    }

    func prepareForUpdateTermination() -> Bool {
        runtime.service(RelayServices.UpdateService.self)?.prepareForApplicationTermination() ?? false
    }

    /// Replaces the features supplied from outside the app target (used to prove the extension path).
    func setAdditionalFeatures(_ features: [FeatureNode]) async throws {
        additionalFeatures = features
        try await apply()
    }

    func setRemoteFilesOpen(_ open: Bool) async throws {
        guard !stopping else { throw CancellationError() }
        remoteFilesOpen = open
        try await apply()
    }

    func openRemoteFiles() {
        guard !stopping else { return }
        if remoteFilesOpen, let windows, let model = windows.model { windows.show(model: model); return }
        Task {
            do { try await setRemoteFilesOpen(true) } catch { errorMessage = error.localizedDescription }
        }
    }

    func closeRemoteFiles() {
        guard !stopping, remoteFilesOpen else { return }
        Task {
            do { try await setRemoteFilesOpen(false) } catch { errorMessage = error.localizedDescription }
        }
    }

    func revokeFrame() { runtime.service(RelayServices.FrameHost.self)?.revoke() }

    /// Shows the Plugins window, creating it the first time.
    func showPlugins() {
        guard !stopping, environment.showsWindows else { return }
        if pluginsWindow == nil {
            let composer = PluginComposer(runtime: runtime, plugins: plugins, isEnabled: { [weak self] plugin in
                self?.isPluginEnabled(plugin) ?? false
            }, setEnabled: { [weak self] plugin, enabled in
                try await self?.setPlugin(plugin, enabled: enabled)
            })
            pluginsWindow = RelayPluginsWindowController(composer: composer)
        }
        pluginsWindow?.show()
    }

    /// Shows the Settings window, creating it the first time; a second request focuses it.
    func showSettings() {
        guard !stopping, environment.showsWindows else { return }
        if settingsWindow == nil { settingsWindow = RelaySettingsWindowController(composition: self) }
        settingsWindow?.show()
    }

    // MARK: Settings

    private func update(_ change: (inout RelayBarPreferences) throws -> Void) async throws {
        guard !stopping else { throw CancellationError() }
        try preferences.update(change)
        try await apply()
    }

    func setRetryLimit(_ limit: Int) async throws { try await update { $0.retryLimit = limit } }

    func setAutomaticUpdates(_ enabled: Bool) async throws {
        try await update { $0.automaticallyChecksForUpdates = enabled }
    }

    /// Before the document has loaded, the saved choice is read directly, as Paper Appearance is.
    func isPluginEnabled(_ plugin: PluginDescriptor) -> Bool {
        (preferences.peek() ?? preferences.value).plugins.isEnabled(plugin)
    }

    /// Open in Frame's default can differ at the next launch, so its choice is pinned even when it matches today's.
    func setPlugin(_ plugin: PluginDescriptor, enabled: Bool) async throws {
        let pins = plugin.id == framePlugin.id
        try await update { pins ? $0.plugins.pin(plugin, enabled: enabled) : $0.plugins.set(plugin, enabled: enabled) }
    }

    func previewEnabled(_ kind: String) -> Bool { preferences.value.preview(kind).enabled }
    func previewLimit(_ kind: String) -> Int64 { preferences.value.preview(kind).maximumBytes }

    func setPreviewEnabled(_ kind: String, _ enabled: Bool) async throws {
        try await update { preferences in
            var preview = preferences.preview(kind)
            preview.enabled = enabled
            preferences.previews[kind] = preview
        }
    }

    func setPreviewLimit(_ kind: String, _ bytes: Int64) async throws {
        _ = try RemotePreviewPlugins.descriptor(kind, maximumBytes: bytes)
        try await update { preferences in
            var preview = preferences.preview(kind)
            preview.maximumBytes = bytes
            preferences.previews[kind] = preview
        }
    }
}
