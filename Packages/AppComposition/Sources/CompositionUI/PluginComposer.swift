import Combine
import Composition
import Foundation

/// The state behind `PluginComposerView`: the catalog, which plugins are on, the feature graph and the selection.
@MainActor
public final class PluginComposer: ObservableObject {
    /// The full id of the selected feature, if any.
    @Published public var selection: String?
    /// The last failure to switch a plugin, shown once at the bottom of the plugin list.
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var graph: FeatureGraph
    @Published private(set) var enabled: Set<String>
    public let plugins: [PluginDescriptor]

    private let runtime: FeatureRuntime?
    private let readEnabled: (@MainActor (PluginDescriptor) -> Bool)?
    private let writeEnabled: (@MainActor (PluginDescriptor, Bool) async throws -> Void)?
    private let fixedDependents: [String: [String]]
    private var globalChoice: (@MainActor (PluginDescriptor) -> Bool?)?
    private var readHost: (@MainActor (PluginDescriptor, String) -> PluginHostChoice)?
    private var writeHost: (@MainActor (PluginDescriptor, String, PluginHostChoice) async throws -> Void)?
    private struct PendingSwitch<Value> {
        let value: Value
        let revision: UUID
        let task: Task<Void, Never>

        /// Store successive edits to one switch in tap order across suspension points.
        @MainActor init(value: Value, after previous: Self?, store: @escaping @MainActor () async throws -> Void,
                        finished: @escaping @MainActor (UUID, String?) -> Void) {
            self.value = value
            let revision = UUID()
            self.revision = revision
            task = Task {
                await previous?.task.value
                do {
                    try await store()
                    finished(revision, nil)
                } catch {
                    finished(revision, error.localizedDescription)
                }
            }
        }
    }
    private var pendingGlobal: [String: PendingSwitch<Bool>] = [:]
    private struct HostSwitch: Hashable {
        let plugin: String
        let realm: String
    }
    private var pendingHosts: [HostSwitch: PendingSwitch<PluginHostChoice>] = [:]
    private var subscription: AnyCancellable?

    /// Live: follows a runtime. `setEnabled` stores the choice and applies the new tree.
    public init(runtime: FeatureRuntime, plugins: [PluginDescriptor],
                isEnabled: @escaping @MainActor (PluginDescriptor) -> Bool,
                setEnabled: @escaping @MainActor (PluginDescriptor, Bool) async throws -> Void) {
        self.runtime = runtime
        self.plugins = plugins
        readEnabled = isEnabled
        writeEnabled = setEnabled
        fixedDependents = [:]
        graph = runtime.graph
        enabled = Set(plugins.filter(isEnabled).map(\.id))
        subscription = runtime.$graph.dropFirst().sink { [weak self] graph in
            self?.follow(graph)
        }
    }

    /// A profile-backed composer. A nil global choice means the catalog default.
    public convenience init(runtime: FeatureRuntime, plugins: [PluginDescriptor],
                            globalChoice: @escaping @MainActor (PluginDescriptor) -> Bool?,
                            setEnabled: @escaping @MainActor (PluginDescriptor, Bool) async throws -> Void,
                            hostChoice: @escaping @MainActor (PluginDescriptor, String) -> PluginHostChoice,
                            setHostChoice: @escaping @MainActor (PluginDescriptor, String, PluginHostChoice) async throws -> Void) {
        self.init(runtime: runtime, plugins: plugins,
                  isEnabled: { globalChoice($0) ?? $0.isOnByDefault }, setEnabled: setEnabled)
        self.globalChoice = globalChoice
        self.readHost = hostChoice
        self.writeHost = setHostChoice
    }

    public var supportsHostChoices: Bool { writeHost != nil }

    public func hostChoice(for plugin: PluginDescriptor, in realm: String) -> PluginHostChoice {
        let key = HostSwitch(plugin: plugin.id, realm: realm)
        return pendingHosts[key]?.value ?? readHost?(plugin, realm) ?? .inherit
    }

    /// Reads committed choices so a tree rebuild cannot consume an edit still being stored.
    public func effectiveState(for plugin: PluginDescriptor, in realm: String?) -> PluginEffectiveState {
        if let realm {
            let choice = readHost?(plugin, realm) ?? .inherit
            if choice != .inherit { return .init(isEnabled: choice == .on, source: .host) }
        }
        if let on = globalChoice?(plugin) {
            return .init(isEnabled: on, source: .global)
        }
        // The original initializer supplies only the resolved Boolean, without storage provenance.
        if globalChoice == nil {
            let on = readEnabled?(plugin) ?? isEnabled(plugin)
            if on != plugin.isOnByDefault { return .init(isEnabled: on, source: .global) }
        }
        return .init(isEnabled: plugin.isOnByDefault, source: .pluginDefault)
    }

    /// Stores through the profile owner, which applies the resulting tree.
    public func setHostChoice(_ choice: PluginHostChoice, for plugin: PluginDescriptor, in realm: String) async {
        guard let writeHost else { return }
        let key = HostSwitch(plugin: plugin.id, realm: realm)
        let update = PendingSwitch(value: choice, after: pendingHosts[key]) {
            try await writeHost(plugin, realm, choice)
        } finished: { [self] revision, failure in
            guard pendingHosts[key]?.revision == revision else { return }
            pendingHosts[key] = nil
            errorMessage = failure
        }
        objectWillChange.send()
        pendingHosts[key] = update
        await update.task.value
    }

    /// Static: for previews and snapshots. `enabled` holds plugin ids; `dependents` is keyed by feature id.
    public init(graph: FeatureGraph, plugins: [PluginDescriptor], enabled: Set<String>,
                dependents: [String: [String]] = [:]) {
        runtime = nil
        self.plugins = plugins
        readEnabled = nil
        writeEnabled = nil
        fixedDependents = dependents
        self.graph = graph
        self.enabled = enabled
    }

    public func isEnabled(_ plugin: PluginDescriptor) -> Bool {
        enabled.contains(plugin.id)
    }

    /// Shows the new state at once and reverts it if storing the choice fails.
    public func setEnabled(_ plugin: PluginDescriptor, _ on: Bool) {
        if on {
            enabled.insert(plugin.id)
        } else {
            enabled.remove(plugin.id)
        }
        guard let writeEnabled else { return }
        pendingGlobal[plugin.id] = PendingSwitch(value: on, after: pendingGlobal[plugin.id]) {
            try await writeEnabled(plugin, on)
        } finished: { [self] revision, failure in
            guard pendingGlobal[plugin.id]?.revision == revision else { return }
            pendingGlobal[plugin.id] = nil
            errorMessage = failure
            refreshEnabled()
        }
    }

    public func retry(_ id: String) {
        runtime?.retry(id)
    }

    public func dependents(of id: String) -> [String] {
        runtime?.dependents(of: id) ?? fixedDependents[id] ?? []
    }

    public func node(_ id: String?) -> FeatureGraph.Node? {
        id.flatMap { id in graph.nodes.first { $0.id == id } }
    }

    /// The plugin that contributes a feature, if any.
    public func plugin(owning node: FeatureGraph.Node) -> PluginDescriptor? {
        plugins.first { $0.owns(node.id, inRealm: node.container) }
    }

    /// The feature to report under an enabled plugin's row: a failure, then a stuck feature, and a waiting
    /// one only while none of the plugin's features is running.
    public func trouble(of plugin: PluginDescriptor) -> FeatureGraph.Node? {
        guard isEnabled(plugin) else { return nil }
        return trouble(in: members(of: plugin))
    }

    func trouble(in present: [FeatureGraph.Node]) -> FeatureGraph.Node? {
        if let failed = present.first(where: { $0.phase.kind == .failed }) {
            return failed
        }
        if let stuck = present.first(where: { $0.phase.kind == .stuck }) {
            return stuck
        }
        guard !present.contains(where: { $0.phase.kind == .running }) else { return nil }
        return present.first { $0.phase.kind == .waiting }
    }

    /// Selects the plugin's first feature when it is on the map.
    public func reveal(_ plugin: PluginDescriptor) {
        if let first = plugin.features.first, node(first) != nil {
            selection = first
        } else if !plugin.realmRelativeFeatures.isEmpty,
                  let first = graph.nodes.first(where: { plugin.owns($0.id, inRealm: $0.container) }) {
            selection = first.id
        }
    }

    private func follow(_ next: FeatureGraph) {
        graph = next
        refreshEnabled()
        if let selection, !next.nodes.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func refreshEnabled() {
        guard let readEnabled else { return }
        enabled = Set(plugins.filter { pendingGlobal[$0.id]?.value ?? readEnabled($0) }.map(\.id))
    }
}

/// The five states a person is shown, each with its own mark.
enum PhaseKind: CaseIterable {
    case running
    case waiting
    case changing
    case failed
    case stuck

    var word: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .changing: return "Changing"
        case .failed: return "Failed"
        case .stuck: return "Stuck"
        }
    }
}

extension FeaturePhase {
    var kind: PhaseKind {
        switch self {
        case .active: return .running
        case .pending: return .waiting
        case .loading, .draining, .unloading: return .changing
        case .failed: return .failed
        case .stuck: return .stuck
        }
    }

    var reason: String? {
        switch self {
        case .pending(let text), .failed(let text), .stuck(let text): return text
        case .active, .loading, .draining, .unloading: return nil
        }
    }
}

extension FeatureGraph {
    /// The selected feature, everything it depends on and everything that depends on it, transitively,
    /// with the need edges along those paths. A feature parent counts as a dependency of its children.
    func neighbourhood(of id: String) -> (nodes: Set<String>, edges: Set<String>) {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func featureParent(_ node: Node?) -> String? {
            guard let parent = node?.parent, byID[parent]?.isContainer == false else { return nil }
            return parent
        }
        func reach(_ next: (String) -> [String]) -> Set<String> {
            var seen: Set<String> = [id]
            var queue = [id]
            while let current = queue.popLast() {
                for other in next(current) where seen.insert(other).inserted {
                    queue.append(other)
                }
            }
            return seen
        }
        let upstream = reach { current in
            edges.filter { $0.consumer == current }.compactMap(\.provider) + [featureParent(byID[current])].compactMap { $0 }
        }
        let downstream = reach { current in
            edges.filter { $0.provider == current }.map(\.consumer) + nodes.filter { featureParent($0) == current }.map(\.id)
        }
        let path = edges.filter { edge in
            guard let provider = edge.provider else { return false }
            let up = upstream.contains(provider) && upstream.contains(edge.consumer)
            let down = downstream.contains(provider) && downstream.contains(edge.consumer)
            return up || down
        }
        return (upstream.union(downstream), Set(path.map(\.id)))
    }
}
