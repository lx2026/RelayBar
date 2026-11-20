import Foundation

/// A description of the wanted tree: one node per feature and one edge per need.
/// The runtime publishes it; a view draws it without reaching into the runtime.
public struct FeatureGraph: Equatable, Sendable {
    /// One wanted feature.
    public struct Node: Identifiable, Equatable, Sendable {
        /// The full path id, such as `remote/thumbnails`.
        public let id: String
        /// The last path component.
        public let name: String
        /// The full id of the parent node, if any.
        public let parent: String?
        /// The id of the nearest ancestor realm or group container; `nil` at the root.
        public let container: String?
        /// True for a realm or group node, which has no behaviour of its own.
        public let isContainer: Bool
        public let phase: FeaturePhase
        /// Increases each time the feature loads.
        public let generation: UInt64
        /// Names of the services it needs, in declaration order.
        public let needs: [String]
        /// Names of the services it may offer, in declaration order.
        public let offers: [String]

        /// Describes a node directly, for previews and fixtures.
        public init(id: String, name: String, parent: String?, container: String?, isContainer: Bool,
                    phase: FeaturePhase, generation: UInt64, needs: [String], offers: [String]) {
            self.id = id
            self.name = name
            self.parent = parent
            self.container = container
            self.isContainer = isContainer
            self.phase = phase
            self.generation = generation
            self.needs = needs
            self.offers = offers
        }
    }

    /// One need of one feature.
    public struct Edge: Identifiable, Equatable, Sendable {
        public let service: String
        /// The feature that offers the service in the consumer's realm; `nil` when no feature does.
        public let provider: String?
        public let consumer: String
        /// True when the consumer currently holds, or could now get, a live value.
        public let isSatisfied: Bool
        public var id: String { "\(provider ?? "-")>\(consumer):\(service)" }

        /// Describes an edge directly, for previews and fixtures.
        public init(service: String, provider: String?, consumer: String, isSatisfied: Bool) {
            self.service = service
            self.provider = provider
            self.consumer = consumer
            self.isSatisfied = isSatisfied
        }
    }

    /// Every wanted feature, in tree order.
    public let nodes: [Node]
    /// Every need, ordered by consumer in tree order and then by declaration.
    public let edges: [Edge]

    /// Describes a graph directly, for previews and fixtures.
    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

extension FeatureGraph {
    /// Reads the runtime's own bookkeeping; nothing here is tracked separately.
    init(order: [String], plans: [String: FeatureRuntime.Plan], fibers: [String: FeatureRuntime.Fiber],
         providers: [FeatureRuntime.SlotID: String], table: [FeatureRuntime.SlotID: FeatureRuntime.Binding]) {
        var nodes: [Node] = []
        var edges: [Edge] = []
        for id in order {
            guard let plan = plans[id] else { continue }
            var container = plan.parent
            while let ancestor = container, let above = plans[ancestor], !above.node.isRealm {
                container = above.parent
            }
            let fiber = fibers[id]
            nodes.append(Node(id: id, name: plan.node.id, parent: plan.parent, container: container,
                              isContainer: plan.node.isRealm,
                              phase: fiber?.phase ?? .pending("Not loaded yet"), generation: fiber?.generation ?? 0,
                              needs: plan.needs.map(\.name), offers: plan.offers.map(\.name)))
            for need in plan.needs {
                edges.append(Edge(service: need.name, provider: providers[need.slot], consumer: id,
                                  isSatisfied: table[need.slot]?.live == true))
            }
        }
        self.init(nodes: nodes, edges: edges)
    }

    /// Every wanted feature that would unload if `id` were removed: its descendants and the consumers
    /// of anything it offers, transitively, in tree order and without `id` itself.
    static func dependents(of id: String, order: [String], plans: [String: FeatureRuntime.Plan],
                           providers: [FeatureRuntime.SlotID: String]) -> [String] {
        guard plans[id] != nil else { return [] }
        var removed: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for other in order where !removed.contains(other) {
                guard let plan = plans[other] else { continue }
                let orphaned = plan.parent.map { removed.contains($0) } ?? false
                let starved = plan.needs.contains { need in providers[need.slot].map { removed.contains($0) } ?? false }
                if orphaned || starved {
                    removed.insert(other)
                    changed = true
                }
            }
        }
        return order.filter { $0 != id && removed.contains($0) }
    }
}
