import Composition
import CoreGraphics

/// Where each feature of a graph is drawn. A pure function of the graph, so it can be tested without a window.
///
/// The column of a feature is its dependency depth: providers sit left of their consumers and a child
/// sits right of its feature parent. Rows are grouped: first the features outside any container, then one
/// group per top-level container in tree order, with nested containers stacked inside their parent's group.
/// Columns are shared by all groups.
public struct FeatureMapLayout: Equatable {
    /// The size of one feature node.
    public static let nodeSize = CGSize(width: 140, height: 30)
    public static let columnGap: CGFloat = 40
    public static let rowGap: CGFloat = 6
    public static let groupGap: CGFloat = 24
    /// Space between a container's edge and its nodes.
    public static let containerPadding: CGFloat = 12
    /// Extra space at the top of a container for its label.
    public static let containerLabel: CGFloat = 18

    /// Frames of the drawn features, keyed by full id. Container nodes are not included.
    public let nodes: [String: CGRect]
    /// Frames of the containers that hold at least one feature, keyed by full id.
    public let containers: [String: CGRect]
    /// The dependency depth of each drawn feature.
    public let columns: [String: Int]
    /// The extent of every frame, starting at the origin.
    public let size: CGSize

    /// Lays out a graph.
    public init(_ graph: FeatureGraph) {
        let byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var inputs: [String: [String]] = [:]
        for edge in graph.edges {
            if let provider = edge.provider {
                inputs[edge.consumer, default: []].append(provider)
            }
        }

        var columns: [String: Int] = [:]
        var visiting: Set<String> = []
        // A dependency cycle cannot load; the edge that closes it is ignored so the layout still terminates.
        func depth(_ id: String) -> Int {
            if let known = columns[id] {
                return known
            }
            guard let node = byID[id], !visiting.contains(id) else {
                return -1
            }
            visiting.insert(id)
            var sources = inputs[id] ?? []
            if let parent = node.parent, let above = byID[parent], !above.isContainer {
                sources.append(parent)
            }
            let result = sources.map { depth($0) + 1 }.max() ?? 0
            visiting.remove(id)
            columns[id] = max(result, 0)
            return max(result, 0)
        }
        for node in graph.nodes where !node.isContainer {
            _ = depth(node.id)
        }

        let width = Self.nodeSize.width
        let height = Self.nodeSize.height
        let padding = Self.containerPadding
        var nodes: [String: CGRect] = [:]
        var containers: [String: CGRect] = [:]

        // Places one group's own features, then its nested containers beneath them. Returns the group's bottom.
        func place(_ group: String?, top: CGFloat) -> CGFloat {
            var rows: [Int: Int] = [:]
            var tallest = 0
            for node in graph.nodes where !node.isContainer && node.container == group {
                let column = columns[node.id] ?? 0
                let row = rows[column, default: 0]
                rows[column] = row + 1
                tallest = max(tallest, row + 1)
                let origin = CGPoint(x: CGFloat(column) * (width + Self.columnGap),
                                     y: top + CGFloat(row) * (height + Self.rowGap))
                nodes[node.id] = CGRect(origin: origin, size: Self.nodeSize)
            }
            var bottom = tallest > 0 ? top + CGFloat(tallest) * (height + Self.rowGap) - Self.rowGap : top
            var placedAny = tallest > 0
            for child in graph.nodes where child.isContainer && child.container == group {
                let start = placedAny ? bottom + Self.groupGap : bottom
                _ = place(child.id, top: start + padding + Self.containerLabel)
                let enclosed = graph.nodes
                    .filter { $0.container == child.id }
                    .compactMap { $0.isContainer ? containers[$0.id] : nodes[$0.id] }
                    .reduce(CGRect.null) { $0.union($1) }
                guard !enclosed.isNull else { continue }
                let frame = CGRect(x: enclosed.minX - padding, y: enclosed.minY - padding - Self.containerLabel,
                                   width: enclosed.width + 2 * padding,
                                   height: enclosed.height + 2 * padding + Self.containerLabel)
                containers[child.id] = frame
                bottom = frame.maxY
                placedAny = true
            }
            return bottom
        }
        _ = place(nil, top: 0)

        let all = (Array(nodes.values) + Array(containers.values)).reduce(CGRect.null) { $0.union($1) }
        let shift = all.isNull ? .zero : CGPoint(x: -all.minX, y: -all.minY)
        self.nodes = nodes.mapValues { $0.offsetBy(dx: shift.x, dy: shift.y) }
        self.containers = containers.mapValues { $0.offsetBy(dx: shift.x, dy: shift.y) }
        self.columns = columns.filter { nodes[$0.key] != nil }
        size = all.isNull ? .zero : all.size
    }

    /// The provider's trailing centre and the consumer's leading centre, or `nil` when either is not drawn.
    public func endpoints(provider: String, consumer: String) -> (start: CGPoint, end: CGPoint)? {
        guard let from = nodes[provider], let to = nodes[consumer] else { return nil }
        return (CGPoint(x: from.maxX, y: from.midY), CGPoint(x: to.minX, y: to.midY))
    }
}
