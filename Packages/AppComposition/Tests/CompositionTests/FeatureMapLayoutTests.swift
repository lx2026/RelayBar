import Composition
import CompositionUI
import CoreGraphics
import XCTest

final class FeatureMapLayoutTests: XCTestCase {
    private let graph = ComposerFixture.graph

    func testProvidersSitLeftOfTheirConsumers() {
        let layout = FeatureMapLayout(graph)
        let drawn = graph.edges.filter { $0.provider != nil }
        XCTAssertFalse(drawn.isEmpty)
        for edge in drawn {
            guard let provider = edge.provider,
                  let from = layout.nodes[provider], let to = layout.nodes[edge.consumer] else {
                return XCTFail("\(edge.id) has no frame")
            }
            XCTAssertLessThan(from.maxX, to.minX, edge.id)
        }
        XCTAssertEqual(layout.columns["access"], 0)
        XCTAssertEqual(layout.columns["remote/source"], 1)
        XCTAssertEqual(layout.columns["remote/preview.image"], 3)
    }

    func testNoTwoNodesOverlapAndContainersAreNotDrawnAsNodes() {
        let layout = FeatureMapLayout(graph)
        XCTAssertEqual(Set(layout.nodes.keys), Set(graph.nodes.filter { !$0.isContainer }.map(\.id)))
        let frames = Array(layout.nodes)
        for (index, first) in frames.enumerated() {
            XCTAssertEqual(first.value.size, FeatureMapLayout.nodeSize)
            for second in frames[(index + 1)...] {
                XCTAssertFalse(first.value.intersects(second.value), "\(first.key) overlaps \(second.key)")
            }
        }
    }

    func testEachContainerEnclosesExactlyItsMembers() {
        let layout = FeatureMapLayout(graph)
        XCTAssertEqual(Array(layout.containers.keys), ["remote"])
        for (container, frame) in layout.containers {
            let members = graph.nodes.filter { !$0.isContainer && $0.container == container }
            let enclosed = members.compactMap { layout.nodes[$0.id] }.reduce(CGRect.null) { $0.union($1) }
            let padding = FeatureMapLayout.containerPadding
            XCTAssertEqual(frame, CGRect(x: enclosed.minX - padding,
                                         y: enclosed.minY - padding - FeatureMapLayout.containerLabel,
                                         width: enclosed.width + 2 * padding,
                                         height: enclosed.height + 2 * padding + FeatureMapLayout.containerLabel))
            for (id, node) in layout.nodes {
                if members.contains(where: { $0.id == id }) {
                    XCTAssertTrue(frame.contains(node), "\(container) leaves out \(id)")
                } else {
                    XCTAssertFalse(frame.intersects(node), "\(container) takes in \(id)")
                }
            }
        }
    }

    func testSpacingFollowsTheMetrics() throws {
        let layout = FeatureMapLayout(graph)
        let access = try XCTUnwrap(layout.nodes["access"])
        let documents = try XCTUnwrap(layout.nodes["documents"])
        let thumbnails = try XCTUnwrap(layout.nodes["thumbnails"])
        let remote = try XCTUnwrap(layout.containers["remote"])
        XCTAssertEqual(thumbnails.minX - access.maxX, FeatureMapLayout.columnGap)
        XCTAssertEqual(documents.minY - access.maxY, FeatureMapLayout.rowGap)
        let rootBottom = graph.nodes.filter { $0.container == nil }.compactMap { layout.nodes[$0.id]?.maxY }.max() ?? 0
        XCTAssertEqual(remote.minY - rootBottom, FeatureMapLayout.groupGap)
    }

    func testTheSameGraphGivesTheSameLayout() {
        let first = FeatureMapLayout(graph)
        XCTAssertEqual(first, FeatureMapLayout(graph))
        let bounds = (Array(first.nodes.values) + Array(first.containers.values)).reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(bounds.origin, .zero)
        XCTAssertEqual(bounds.size, first.size)
    }
}
