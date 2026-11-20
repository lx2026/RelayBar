import Composition
import HouseStyle
import SwiftUI

/// Regular-width Plugins screen, with the selected feature shared with the composer.
public struct MobilePluginsWorkspace: View {
    @ObservedObject private var composer: PluginComposer
    private let groupTitle: (PluginDescriptor) -> String
    private let realmTitle: (String) -> String
    @State private var host: String?
    @State private var detail: PluginDescriptor?
    @HouseTracking private var house

    public init(composer: PluginComposer, groupTitle: @escaping (PluginDescriptor) -> String,
                realmTitle: @escaping (String) -> String = { $0 }) {
        self.composer = composer
        self.groupTitle = groupTitle
        self.realmTitle = realmTitle
    }

    public var body: some View {
        let realms = composer.graph.nodes.filter(\.isContainer)
        let graph = composer.graph.filtered(to: host)
        GeometryReader { geometry in
            HStack(spacing: 0) {
                MobilePluginsList(composer: composer, groupTitle: groupTitle, realmTitle: realmTitle) { plugin in
                    if let node = graph.nodes.first(where: { !$0.isContainer && plugin.owns($0.id, inRealm: $0.container) }) {
                        composer.selection = node.id
                    } else {
                        detail = plugin
                    }
                }
                .frame(width: min(320, geometry.size.width * 0.27))
                HouseDivider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Feature map").font(.title2.bold())
                    ViewThatFits(in: .horizontal) {
                        Picker("Host", selection: hostBinding) { hostOptions(realms) }
                            .pickerStyle(.segmented).fixedSize()
                        Picker("Host", selection: hostBinding) { hostOptions(realms) }.pickerStyle(.menu)
                    }
                    MobileFeatureMap(composer: composer, graph: graph, realmTitle: realmTitle)
                    ViewThatFits(in: .horizontal) {
                        HStack { legend }
                        VStack(alignment: .leading) { legend }
                    }
                    .font(.caption).foregroundStyle(HouseColor.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12).background(HouseColor.paper)
                HouseDivider()
                ScrollView {
                    if let node = graph.nodes.first(where: { $0.id == composer.selection }) {
                        let plugin = composer.plugin(owning: node)
                        VStack(alignment: .leading, spacing: 16) {
                            FeatureStatus(node: node, displayID: displayID(node.id), idFirst: true)
                            if let plugin {
                                DetailSection("Plugin", card: false) {
                                    Button(plugin.title) { detail = plugin }.buttonStyle(.plain)
                                }
                            }
                            FeatureRelations(composer: composer, nodes: [node],
                                             unloads: plugin == nil ? nil : composer.dependents(of: node.id), inspector: true, displayID: displayID)
                        }
                        .padding(16)
                    } else {
                        Text("Select a feature to see what it needs and offers.")
                            .foregroundStyle(HouseColor.muted).padding(16)
                    }
                }
                .frame(width: min(270, geometry.size.width * 0.23))
                .background(HouseColor.panel)
            }
        }
        .foregroundStyle(HouseColor.ink)
        .tint(HouseColor.accent)
        .onReceive(composer.$graph) { next in
            if let host, !next.nodes.contains(where: { $0.id == host }) { self.host = nil }
        }
        .sheet(item: $detail) { plugin in
            VStack(alignment: .trailing) {
                Button("Done") { detail = nil }.padding(.horizontal)
                MobilePluginDetail(composer: composer, plugin: plugin, realmTitle: realmTitle)
            }
            .padding(.top)
        }
    }

    private func displayID(_ id: String) -> String {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard let realm = parts.first, composer.graph.nodes.contains(where: { $0.isContainer && $0.id == realm })
        else { return id }
        return ([realmTitle(realm)] + parts.dropFirst()).joined(separator: "/")
    }

    @ViewBuilder private var legend: some View {
        HStack(spacing: 4) { StatusMark(kind: .running); Text("Running") }
        HStack(spacing: 4) { StatusMark(kind: .waiting); Text("Waiting") }
        Label("Plugin", systemImage: "rectangle").foregroundStyle(HouseColor.accent)
    }

    private var hostBinding: Binding<String?> {
        Binding(get: { host }, set: { realm in
            host = realm
            if !composer.graph.filtered(to: realm).nodes.contains(where: { $0.id == composer.selection }) {
                composer.selection = nil
            }
        })
    }

    @ViewBuilder private func hostOptions(_ realms: [FeatureGraph.Node]) -> some View {
        Text("All hosts").tag(nil as String?)
        ForEach(realms) { realm in Text(realmTitle(realm.id)).tag(Optional(realm.id)) }
    }
}

extension FeatureGraph {
    /// Keep the app features and ancestor containers so cross-realm needs retain their providers.
    func filtered(to realm: String?) -> FeatureGraph {
        guard let realm, nodes.contains(where: { $0.isContainer && $0.id == realm }) else { return self }
        let visible = nodes.filter { node in
            guard let container = node.isContainer ? node.id : node.container else { return true }
            return container == realm || realm.hasPrefix(container + "/") || container.hasPrefix(realm + "/")
        }
        let ids = Set(visible.map(\.id))
        return FeatureGraph(nodes: visible, edges: edges.filter { ids.contains($0.consumer) })
    }
}

private struct MobileFeatureMap: View {
    @ObservedObject var composer: PluginComposer
    let graph: FeatureGraph
    let realmTitle: (String) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pixelLength) private var pixelLength
    @ScaledMetric(relativeTo: .footnote) private var unit: CGFloat = 1
    @HouseTracking private var house

    var body: some View {
        let layout = FeatureMapLayout(graph)
        let scale = CGAffineTransform(scaleX: unit, y: unit * 1.5)
        let focus = composer.selection.map { graph.neighbourhood(of: $0) }
        ScrollViewReader { reader in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(graph.nodes.filter(\.isContainer)) { realm in
                        if let frame = layout.containers[realm.id]?.applying(scale) {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(HouseColor.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .overlay(alignment: .topLeading) {
                                    Text(realmTitle(realm.id)).font(.caption.bold())
                                        .foregroundStyle(HouseColor.muted).padding(.horizontal, 8).padding(.top, 4)
                                }
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                    ForEach(FeatureMapLink.group(graph.edges, focus: focus?.edges)) { link in
                        if let ends = layout.endpoints(provider: link.provider, consumer: link.consumer) {
                            EdgeCurve(start: ends.start.applying(scale), end: ends.end.applying(scale))
                                .stroke(link.isFocused ? HouseColor.accent : link.color,
                                        style: StrokeStyle(lineWidth: pixelLength * (link.isFocused ? 1.5 : 1),
                                                           lineCap: .round, dash: link.stroke.dash))
                                .opacity(focus == nil || link.isFocused ? 1 : 0.35)
                                .accessibilityHidden(true)
                        }
                    }
                    PlacedFrames {
                        ForEach(graph.nodes) { node in
                            if let frame = layout.nodes[node.id]?.applying(scale) {
                                card(node)
                                    .opacity(focus?.nodes.contains(node.id) == false ? 0.35 : 1)
                                    .id(node.id)
                                    .layoutValue(key: PlacedFrame.self, value: frame)
                            }
                        }
                    }
                }
                .frame(width: layout.size.width * scale.a, height: layout.size.height * scale.d)
                .padding(4)
            }
            .onReceive(composer.$selection) { if let id = $0 { reader.scrollTo(id) } }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: composer.selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func card(_ node: FeatureGraph.Node) -> some View {
        let selected = composer.selection == node.id
        let marked = composer.plugin(owning: node) != nil
        let shape = RoundedRectangle(cornerRadius: 10)
        return Button { composer.selection = node.id } label: {
            HStack(spacing: 5) {
                StatusMark(kind: node.phase.kind)
                Text(node.name).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(HouseColor.card, in: shape)
            .overlay(shape.fill(HouseColor.accent.opacity(selected ? 0.08 : 0)))
            .overlay(shape.strokeBorder(selected || marked ? HouseColor.accent : HouseColor.line,
                                       lineWidth: selected ? 2 : (marked ? 1.5 : 1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([node.id, marked ? "Plugin" : nil, node.phase.kind.word, node.phase.reason]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
