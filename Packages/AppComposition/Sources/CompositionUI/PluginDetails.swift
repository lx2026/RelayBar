import Composition
import Foundation

/// A profile stores only explicit host choices. Inherit removes the stored override.
public enum PluginHostChoice: String, CaseIterable, Sendable {
    case inherit, on, off
}

public struct PluginEffectiveState: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case host, global, pluginDefault

        var label: String {
            switch self {
            case .host: "host override"
            case .global: "global choice"
            case .pluginDefault: "plugin default"
            }
        }
    }

    public let isEnabled: Bool
    public let source: Source
}

public struct PluginGroup: Identifiable {
    public var id: String { title }
    public let title: String
    public let plugins: [PluginDescriptor]
}

extension PluginComposer {
    /// Group and plugin order follow the first occurrence in the catalog.
    public func groups(by title: (PluginDescriptor) -> String) -> [PluginGroup] {
        var order: [String] = []
        var members: [String: [PluginDescriptor]] = [:]
        for plugin in plugins {
            let group = title(plugin)
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(plugin)
        }
        return order.map { PluginGroup(title: $0, plugins: members[$0] ?? []) }
    }

    func members(of plugin: PluginDescriptor) -> [FeatureGraph.Node] {
        graph.nodes.filter { plugin.owns($0.id, inRealm: $0.container) }
    }

    func needs(of nodes: [FeatureGraph.Node]) -> [FeatureGraph.Edge] {
        let ids = Set(nodes.map(\.id))
        return graph.edges.filter { ids.contains($0.consumer) }
    }

    struct Offer: Hashable {
        let provider: String
        let service: String
        let consumers: Int
    }

    func offers(of nodes: [FeatureGraph.Node]) -> [Offer] {
        nodes.flatMap { node in
            node.offers.map { service in
                let edges = graph.edges.filter { $0.provider == node.id && $0.service == service }
                return Offer(provider: node.id, service: service, consumers: Set(edges.map(\.consumer)).count)
            }
        }
    }

    func alsoUnloads(with plugin: PluginDescriptor) -> [String] {
        let removed = members(of: plugin).filter { node in
            guard let realm = node.container else { return true }
            return effectiveState(for: plugin, in: realm).source != .host
        }
        let others = Set(removed.flatMap { dependents(of: $0.id) }).subtracting(removed.map(\.id))
        return graph.nodes.map(\.id).filter(others.contains)
    }
}
