import AppKit
import Composition
import HouseStyle
import SwiftUI

/// The Plugins window: the plugin switches, the live feature map and an inspector for the selected feature.
public struct PluginComposerView: View {
    @ObservedObject private var composer: PluginComposer
    @HouseTracking private var house
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shows a composer.
    public init(composer: PluginComposer) {
        self.composer = composer
    }

    public var body: some View {
        HStack(spacing: 0) {
            PluginList(composer: composer)
                .frame(width: 248)
                .background(HouseColor.panel)
            HouseDivider()
            FeatureMap(composer: composer, animation: reduceMotion ? nil : .easeInOut(duration: 0.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HouseColor.paper)
            HouseDivider()
            Inspector(composer: composer)
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(HouseColor.panel)
        }
        .foregroundStyle(HouseColor.ink)
        .frame(minWidth: 900, minHeight: 540)
    }
}

// MARK: - Plugins column

private struct PluginList: View {
    @ObservedObject var composer: PluginComposer
    @HouseTracking private var house

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Plugins")
                    .font(.system(size: 13, weight: .semibold))
                Text("Switch optional features on or off. The map shows what each one needs.")
                    .font(.system(size: 11))
                    .foregroundStyle(HouseColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(composer.plugins) { plugin in
                        PluginRow(composer: composer, plugin: plugin)
                    }
                }
                .padding(.horizontal, 8)
            }
            if let message = composer.errorMessage {
                StatusLine(kind: .failed, message: message)
                    .padding(16)
            }
        }
    }
}

private struct PluginRow: View {
    @ObservedObject var composer: PluginComposer
    let plugin: PluginDescriptor
    @HouseTracking private var house

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            selecting(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: plugin.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                    )
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    selecting(
                        Text(plugin.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    )
                    Spacer(minLength: 0)
                    Toggle(plugin.title, isOn: Binding(
                        get: { composer.isEnabled(plugin) },
                        set: { composer.setEnabled(plugin, $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                selecting(
                    Text(plugin.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(HouseColor.muted)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                )
                if let node = composer.trouble(of: plugin) {
                    StatusLine(kind: node.phase.kind, message: "\(node.phase.kind.word): \(node.phase.reason ?? "")",
                               retry: node.phase.kind == .failed ? { composer.retry(node.id) } : nil)
                        .padding(.top, 6)
                }
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            // A plugin that contributes no feature has nothing on the map to show.
            if !plugin.features.isEmpty {
                Button("Show on Map") { composer.reveal(plugin) }
            }
        }
    }

    /// The icon, title and summary select the plugin's first feature. The switch sits beside them, never inside.
    private func selecting(_ content: some View) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { composer.reveal(plugin) }
    }
}

/// A status mark centred on the first line of its message, with an optional Retry button beneath the message.
private struct StatusLine: View {
    let kind: PhaseKind
    let message: String
    var retry: (() -> Void)?
    private static let firstLineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 11))

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusMark(kind: kind)
                .frame(height: Self.firstLineHeight)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("Retry", action: retry)
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Map

private struct FeatureMap: View {
    @ObservedObject var composer: PluginComposer
    let animation: Animation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { viewport in
                ScrollViewReader { reader in
                    ScrollView([.horizontal, .vertical]) {
                        MapCanvas(composer: composer, animation: animation)
                            .padding(16)
                            .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .onTapGesture { composer.selection = nil }
                    }
                    .onAppear { reveal(composer.selection, with: reader) }
                    .onChange(of: composer.selection) { reveal($0, with: reader) }
                }
            }
            Legend()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private func reveal(_ id: String?, with reader: ScrollViewProxy) {
        guard let id else { return }
        reader.scrollTo(id)
    }
}

/// Places each subview at its `PlacedFrame`. Unlike `position`, every node keeps its own frame,
/// so scrolling to a node's id reveals that node.
private struct PlacedFrames: Layout {
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

private struct PlacedFrame: LayoutValueKey {
    static let defaultValue = CGRect.zero
}

private struct MapCanvas: View {
    @ObservedObject var composer: PluginComposer
    let animation: Animation?
    @HouseTracking private var house

    var body: some View {
        let graph = composer.graph
        let layout = FeatureMapLayout(graph)
        let focus = composer.selection.map { graph.neighbourhood(of: $0) }
        let links = Link.group(graph.edges, focus: focus?.edges)
        ZStack(alignment: .topLeading) {
            ForEach(graph.nodes.filter { layout.containers[$0.id] != nil }) { container in
                if let frame = layout.containers[container.id] {
                    ContainerOutline(name: container.name)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            ForEach(links) { link in
                if let points = layout.endpoints(provider: link.provider, consumer: link.consumer) {
                    EdgeCurve(start: points.start, end: points.end)
                        .stroke(link.color, style: link.stroke)
                        .opacity(focus == nil || link.isFocused ? 1 : 0.35)
                }
            }
            PlacedFrames {
                ForEach(graph.nodes.filter { layout.nodes[$0.id] != nil }) { node in
                    MapNode(node: node, isPlugin: composer.plugin(owning: node.id) != nil,
                            isSelected: composer.selection == node.id)
                        .onTapGesture { composer.selection = node.id }
                        .opacity(isDimmed(node.id, focus) ? 0.35 : 1)
                        .layoutValue(key: PlacedFrame.self, value: layout.nodes[node.id] ?? .zero)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(animation, value: composer.selection)
        .animation(animation, value: layout)
    }

    private func isDimmed(_ id: String, _ focus: (nodes: Set<String>, edges: Set<String>)?) -> Bool {
        guard let focus else { return false }
        return !focus.nodes.contains(id)
    }
}

/// The need edges between one provider and one consumer, drawn as one curve.
private struct Link: Identifiable {
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
        return isSatisfied ? Color.accentColor : HouseColor.retrying
    }

    var stroke: StrokeStyle {
        StrokeStyle(lineWidth: isFocused ? 1.5 : 1, lineCap: .round, dash: isSatisfied ? [] : [4, 3])
    }

    /// Edges without a provider are not drawn; the consumer's waiting reason covers them.
    static func group(_ edges: [FeatureGraph.Edge], focus: Set<String>?) -> [Link] {
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
            return Link(provider: provider, consumer: first.consumer, isSatisfied: members.allSatisfy(\.isSatisfied),
                        isFocused: focus.map { focus in members.contains { focus.contains($0.id) } } ?? false)
        }
    }
}

private struct EdgeCurve: Shape {
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

private struct ContainerOutline: View {
    let name: String
    @HouseTracking private var house

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(HouseColor.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .overlay(alignment: .topLeading) {
                Text(name.uppercased())
                    .font(.system(size: 11))
                    .tracking(0.6)
                    .foregroundStyle(HouseColor.muted)
                    .padding(.leading, FeatureMapLayout.containerPadding)
                    .padding(.top, 8)
            }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(name))
    }
}

private struct MapNode: View {
    let node: FeatureGraph.Node
    let isPlugin: Bool
    let isSelected: Bool
    @HouseTracking private var house

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        HStack(spacing: 4) {
            StatusMark(kind: node.phase.kind)
            Text(node.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            ZStack {
                shape.fill(HouseColor.card)
                shape.fill(Color.accentColor.opacity(isPlugin ? 0.08 : 0))
            }
        )
        .overlay(
            shape.strokeBorder(isPlugin ? Color.accentColor : HouseColor.line, lineWidth: isPlugin ? 1.5 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-3)
                .opacity(isSelected ? 1 : 0)
        )
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        let reason = node.phase.reason.map { ", \($0)" } ?? ""
        return "\(node.id), \(node.phase.kind.word)\(reason)"
    }
}

private struct Legend: View {
    @HouseTracking private var house

    var body: some View {
        HStack(spacing: 14) {
            ForEach(PhaseKind.allCases, id: \.self) { kind in
                HStack(spacing: 5) {
                    StatusMark(kind: kind)
                    Text(kind.word)
                        .font(.system(size: 11))
                        .foregroundStyle(HouseColor.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Marks

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

// MARK: - Inspector

private struct Inspector: View {
    @ObservedObject var composer: PluginComposer
    @HouseTracking private var house

    var body: some View {
        if let node = composer.node(composer.selection) {
            ScrollView(.vertical) {
                details(node)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            Text("Select a feature to see what it needs and offers.")
                .font(.system(size: 12))
                .foregroundStyle(HouseColor.muted)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ node: FeatureGraph.Node) -> some View {
        let edges = composer.graph.edges
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(node.id)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    StatusMark(kind: node.phase.kind)
                    Text(node.phase.kind.word)
                        .font(.system(size: 12))
                }
                if let reason = node.phase.reason {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(HouseColor.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if node.phase.kind == .failed {
                    Button("Retry") { composer.retry(node.id) }
                        .controlSize(.small)
                }
            }
            InspectorSection(title: "Needs", lines: edges.filter { $0.consumer == node.id }.map { edge in
                InspectorLine(name: edge.service, detail: edge.provider.map { "from \($0)" } ?? "nothing offers this")
            })
            InspectorSection(title: "Offers", lines: node.offers.map { service in
                let count = edges.filter { $0.provider == node.id && $0.service == service }.count
                return InspectorLine(name: service, detail: count == 1 ? "1 consumer" : "\(count) consumers")
            })
            if composer.plugin(owning: node.id) != nil {
                let dependents = composer.dependents(of: node.id)
                VStack(alignment: .leading, spacing: 6) {
                    if dependents.isEmpty {
                        Text("Nothing else depends on this.")
                            .font(.system(size: 11))
                            .foregroundStyle(HouseColor.muted)
                    } else {
                        SectionTitle(text: "Turning this off also unloads")
                        ForEach(dependents, id: \.self) { id in
                            Text(id)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

private struct InspectorLine: Hashable {
    let name: String
    let detail: String
}

private struct InspectorSection: View {
    let title: String
    let lines: [InspectorLine]
    @HouseTracking private var house

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            if lines.isEmpty {
                Text("Nothing")
                    .font(.system(size: 11))
                    .foregroundStyle(HouseColor.muted)
            }
            ForEach(lines, id: \.self) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.name)
                        .font(.system(size: 12))
                    Text(line.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(HouseColor.muted)
                }
                .textSelection(.enabled)
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    @HouseTracking private var house

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(HouseColor.muted)
    }
}
