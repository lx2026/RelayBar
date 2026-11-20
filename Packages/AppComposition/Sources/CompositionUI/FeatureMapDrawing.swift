import Composition
import HouseStyle
import SwiftUI

/// The need edges between one provider and one consumer, drawn as one curve.
struct FeatureMapLink: Identifiable {
    let provider: String
    let consumer: String
    let isSatisfied: Bool
    let isFocused: Bool
    var id: String { "\(provider)>\(consumer)" }

    /// Quiet until its path is selected. A waiting half of the tree is an ordinary state, so an edge
    /// without a live value is only dashed at rest and turns orange when someone asks about it.
    var color: Color {
        guard isFocused else {
            return HouseColor.muted.opacity(0.2)
        }
        return isSatisfied ? HouseColor.accent : HouseColor.retrying
    }

    var stroke: StrokeStyle {
        StrokeStyle(lineWidth: isFocused ? 1.5 : 1, lineCap: .round, dash: isSatisfied ? [] : [4, 3])
    }

    /// Edges without a provider are not drawn; the consumer's waiting reason covers them.
    static func group(_ edges: [FeatureGraph.Edge], focus: Set<String>?) -> [FeatureMapLink] {
        var order: [String] = []
        var grouped: [String: [FeatureGraph.Edge]] = [:]
        for edge in edges {
            guard let provider = edge.provider else { continue }
            let key = "\(provider)>\(edge.consumer)"
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(edge)
        }
        return order.compactMap { key in
            guard let members = grouped[key], let first = members.first, let provider = first.provider else { return nil }
            return FeatureMapLink(provider: provider, consumer: first.consumer, isSatisfied: members.allSatisfy(\.isSatisfied),
                        isFocused: focus.map { focus in members.contains { focus.contains($0.id) } } ?? false)
        }
    }
}

struct EdgeCurve: Shape {
    var start: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(start.animatableData, end.animatableData) }
        set {
            start.animatableData = newValue.first
            end.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let bend = max((end.x - start.x) / 2, 24)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        return path
    }
}


/// A distinct shape per state, so colour is never the only signal.
struct StatusMark: View {
    let kind: PhaseKind
    @HouseTracking private var house

    var body: some View {
        Group {
            switch kind {
            case .running:
                Circle()
                    .fill(HouseColor.running)
                    .frame(width: 8, height: 8)
            case .waiting:
                Circle()
                    .strokeBorder(HouseColor.muted, lineWidth: 1.25)
                    .frame(width: 8, height: 8)
            case .changing:
                Circle()
                    .strokeBorder(HouseColor.muted, lineWidth: 1.25)
                    .background(HalfDisc().fill(HouseColor.muted))
                    .frame(width: 8, height: 8)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(HouseColor.failure)
            case .stuck:
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 9.5))
                    .foregroundStyle(HouseColor.retrying)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// The left half of a circle.
private struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: centre)
        path.addArc(center: centre, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Places each subview at its `PlacedFrame`. Unlike `position`, every node keeps its own frame,
/// so scrolling to a node's id reveals that node.
struct PlacedFrames: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.reduce(CGRect.zero) { $0.union($1[PlacedFrame.self]) }.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let frame = subview[PlacedFrame.self]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

struct PlacedFrame: LayoutValueKey {
    static let defaultValue = CGRect.zero
}
