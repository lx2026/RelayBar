import Composition
import HouseStyle
import SwiftUI

private struct PluginDetailSupplement: EnvironmentKey {
    static let defaultValue: @MainActor (PluginDescriptor) -> AnyView = { _ in AnyView(EmptyView()) }
}
public extension View {
    /// App-owned settings for the plugin selected in either mobile layout.
    func pluginDetailSupplement<Content: View>(@ViewBuilder _ content: @escaping @MainActor (PluginDescriptor) -> Content) -> some View {
        environment(\.pluginSupplement, { AnyView(content($0)) })
    }
}
private extension EnvironmentValues {
    var pluginSupplement: @MainActor (PluginDescriptor) -> AnyView {
        get { self[PluginDetailSupplement.self] }
        set { self[PluginDetailSupplement.self] = newValue }
    }
}

public struct MobilePluginDetail: View {
    @Environment(\.pluginHostRealms) private var hostRealms
    @Environment(\.pluginSupplement) private var supplement
    @ObservedObject private var composer: PluginComposer
    private let plugin: PluginDescriptor
    private let realmTitle: (String) -> String
    @Environment(\.dynamicTypeSize) private var typeSize
    @HouseTracking private var house

    public init(composer: PluginComposer, plugin: PluginDescriptor, realmTitle: @escaping (String) -> String = { $0 }) {
        self.composer = composer
        self.plugin = plugin
        self.realmTitle = realmTitle
    }

    public var body: some View {
        let members = composer.members(of: plugin)
        let realms = composer.graph.nodes.filter { node in
            node.isContainer && (!plugin.realmRelativeFeatures.isEmpty || members.contains { $0.container == node.id }
                || plugin.features.contains { $0.hasPrefix(node.id + "/") })
        }
        let heading = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading))
            : AnyLayout(HStackLayout())
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading {
                    PluginTile(symbol: plugin.symbol, size: 48)
                    Text(plugin.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    PluginSwitch(composer: composer, plugin: plugin, status: composer.statusText(plugin, hostRealms: hostRealms, realmTitle: realmTitle))
                }
                Text(plugin.summary)
                if let message = composer.errorMessage { Text(message).foregroundStyle(HouseColor.failure) }
                DetailSection("Status") {
                    ForEach(members.filter { $0.container == nil }) { node in
                        FeatureStatus(node: node, title: "App")
                    }
                    ForEach(realms) { realm in
                        let state = composer.effectiveState(for: plugin, in: realm.id)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(realmTitle(realm.id)).font(.headline)
                            let local = members.filter { $0.container == realm.id }
                            ForEach(local) { node in FeatureStatus(node: node) }
                            if local.isEmpty {
                                Text(state.isEnabled ? "No feature loaded" : "Off").font(.footnote)
                            }
                            if composer.supportsHostChoices {
                                HostChoiceRow(composer: composer, plugin: plugin, realm: realm.id, title: realmTitle(realm.id))
                            }
                        }
                    }
                    if members.isEmpty && realms.isEmpty { Text("No feature loaded") }
                }
                supplement(plugin)
                FeatureRelations(composer: composer, nodes: members, unloads: composer.alsoUnloads(with: plugin))
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(HouseColor.ink).background(HouseColor.paper)
    }
}

private struct HostChoiceRow: View {
    @ObservedObject var composer: PluginComposer
    let plugin: PluginDescriptor
    let realm: String
    let title: String
    @State private var saving = false
    @HouseTracking private var house

    var body: some View {
        let state = composer.effectiveState(for: plugin, in: realm)
        VStack(alignment: .leading) {
            Picker("Choice for " + title, selection: Binding(
                get: { composer.hostChoice(for: plugin, in: realm) },
                set: { choice in
                    saving = true
                    Task {
                        await composer.setHostChoice(choice, for: plugin, in: realm)
                        saving = false
                    }
                }
            )) {
                ForEach(PluginHostChoice.allCases, id: \.self) { choice in
                    Text(choice.rawValue.capitalized).tag(choice)
                }
            }
            .labelsHidden().pickerStyle(.menu).disabled(saving)
            Text("\(state.isEnabled ? "On" : "Off") · \(state.source.label)").font(.caption).foregroundStyle(HouseColor.muted)
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    let card: Bool

    init(_ title: String, card: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.card = card
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PluginSectionTitle(title: title, inset: card ? 14 : 0)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(card ? 14 : 0).frame(maxWidth: .infinity, alignment: .leading)
                .background { if card { PluginCard() } }
        }
    }
}

struct FeatureStatus: View {
    let node: FeatureGraph.Node
    var title: String?
    var displayID: String?
    var idFirst = false
    @HouseTracking private var house
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title { Text(title).font(.headline) }
            if idFirst { Text(displayID ?? node.id).font(.footnote.monospaced().bold()) }
            HStack(spacing: 5) {
                StatusMark(kind: node.phase.kind)
                Text(node.phase.kind.word)
            }
            if let reason = node.phase.reason { Text(reason).foregroundStyle(HouseColor.muted) }
            if !idFirst { Text(node.id).font(.caption.monospaced()).foregroundStyle(HouseColor.muted) }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

struct FeatureRelations: View {
    @ObservedObject var composer: PluginComposer
    let nodes: [FeatureGraph.Node]
    let unloads: [String]?
    var inspector = false
    var displayID: (String) -> String = { $0 }
    @HouseTracking private var house

    var body: some View {
        let needs = composer.needs(of: nodes)
        let offers = composer.offers(of: nodes)
        DetailSection("Needs", card: !inspector) {
            if needs.isEmpty { Text("Nothing") }
            ForEach(needs) { need in
                relation(need.service, detail: need.provider.map { "Offered by " + displayID($0) } ?? "No provider",
                         feature: need.consumer)
            }
        }
        DetailSection("Offers", card: !inspector) {
            if offers.isEmpty { Text("Nothing") }
            ForEach(offers, id: \.self) { offer in
                relation(offer.service, detail: offer.consumers == 1 ? "1 consumer" : "\(offer.consumers) consumers",
                         feature: offer.provider)
            }
        }
        if let unloads {
            DetailSection(inspector ? "Also unloads" : "Turning it off", card: !inspector) {
                if unloads.isEmpty { Text("Nothing else would unload.") }
                ForEach(unloads, id: \.self) { Text(displayID($0)).font(.footnote.monospaced()) }
            }
        }
    }

    private func relation(_ service: String, detail: String, feature: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { relationLabel(service, detail) }
                VStack(alignment: .leading, spacing: 2) { relationLabel(service, detail) }
            }
            if nodes.count > 1 { Text(feature).font(.caption.monospaced()).foregroundStyle(HouseColor.muted) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func relationLabel(_ service: String, _ detail: String) -> some View {
        Text(service).font(.footnote.monospaced())
        Text(detail).font(.footnote).foregroundStyle(HouseColor.muted)
    }
}
