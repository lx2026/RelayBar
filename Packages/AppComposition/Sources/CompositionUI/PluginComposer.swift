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
    @Published private(set) var graph: FeatureGraph
    @Published private(set) var enabled: Set<String>
    let plugins: [PluginDescriptor]

    private let runtime: FeatureRuntime?
    private let readEnabled: (@MainActor (PluginDescriptor) -> Bool)?
    private let writeEnabled: (@MainActor (PluginDescriptor, Bool) async throws -> Void)?
    private let fixedDependents: [String: [String]]
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

    func isEnabled(_ plugin: PluginDescriptor) -> Bool {
        enabled.contains(plugin.id)
    }

    /// Shows the new state at once and reverts it if storing the choice fails.
    func setEnabled(_ plugin: PluginDescriptor, _ on: Bool) {
        if on {
            enabled.insert(plugin.id)
        } else {
            enabled.remove(plugin.id)
        }
        guard let writeEnabled else { return }
        Task {
            do {
                try await writeEnabled(plugin, on)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshEnabled()
        }
    }

    func retry(_ id: String) {
        runtime?.retry(id)
    }

    func dependents(of id: String) -> [String] {
        runtime?.dependents(of: id) ?? fixedDependents[id] ?? []
    }

    func node(_ id: String?) -> FeatureGraph.Node? {
        id.flatMap { id in graph.nodes.first { $0.id == id } }
    }

    /// The plugin that contributes a feature, if any.
    func plugin(owning id: String) -> PluginDescriptor? {
        plugins.first { $0.features.contains(id) }
    }

    /// The feature to report under an enabled plugin's row: a failure, then a stuck feature, and a waiting
    /// one only while none of the plugin's features is running.
    func trouble(of plugin: PluginDescriptor) -> FeatureGraph.Node? {
        guard isEnabled(plugin) else { return nil }
        let present = graph.nodes.filter { plugin.features.contains($0.id) }
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
    func reveal(_ plugin: PluginDescriptor) {
        guard let first = plugin.features.first, node(first) != nil else { return }
        selection = first
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
        enabled = Set(plugins.filter(readEnabled).map(\.id))
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
