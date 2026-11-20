import Composition
import HouseStyle
import SwiftUI

public extension EnvironmentValues {
    /// Saved hosts include profiles whose runtime realm is currently offline.
    @Entry var pluginHostRealms: [String]? = nil
}

/// Place in the Settings navigation stack. Tapping the label opens the detail, and the switch edits in place.
public struct MobilePluginsList: View {
    @ObservedObject var composer: PluginComposer
    let groupTitle: (PluginDescriptor) -> String
    let realmTitle: (String) -> String
    var select: ((PluginDescriptor) -> Void)?
    @Environment(\.pluginHostRealms) private var hostRealms
    @Environment(\.dynamicTypeSize) private var typeSize
    @HouseTracking private var house

    public init(composer: PluginComposer, groupTitle: @escaping (PluginDescriptor) -> String,
                realmTitle: @escaping (String) -> String = { $0 }) {
        self.composer = composer
        self.groupTitle = groupTitle
        self.realmTitle = realmTitle
    }

    init(composer: PluginComposer, groupTitle: @escaping (PluginDescriptor) -> String,
         realmTitle: @escaping (String) -> String, select: @escaping (PluginDescriptor) -> Void) {
        self.init(composer: composer, groupTitle: groupTitle, realmTitle: realmTitle)
        self.select = select
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: select == nil ? 18 : 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plugins").font(select == nil ? .largeTitle.bold() : .title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if select == nil {
                        Text("Built-in features you can switch off. Nothing is downloaded.")
                            .font(.footnote).foregroundStyle(HouseColor.muted)
                    }
                }
                if let error = composer.errorMessage {
                    Text(error).foregroundStyle(HouseColor.failure)
                }
                ForEach(composer.groups(by: groupTitle)) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        PluginSectionTitle(title: group.title)
                        VStack(spacing: 0) {
                            ForEach(group.plugins) { plugin in
                                if select == nil, plugin.id != group.plugins.first?.id {
                                    HouseDivider().padding(.leading, 62)
                                }
                                row(plugin)
                            }
                        }
                        .background {
                            if select == nil { PluginCard() }
                        }
                    }
                }
            }
            .padding(select == nil ? 20 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(HouseColor.ink)
        .background(select == nil ? HouseColor.paper : HouseColor.panel)
    }

    private func row(_ plugin: PluginDescriptor) -> some View {
        let status = composer.statusText(plugin, hostRealms: hostRealms, realmTitle: realmTitle)
        let on = composer.isEnabled(plugin)
        let source = composer.effectiveState(for: plugin, in: nil).source.label
        let selected = composer.node(composer.selection).map { plugin.owns($0.id, inRealm: $0.container) } ?? false
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Group {
                if let select {
                    Button { select(plugin) } label: { rowLabel(plugin, status: status) }
                } else {
                    NavigationLink {
                        MobilePluginDetail(composer: composer, plugin: plugin, realmTitle: realmTitle)
                    } label: { rowLabel(plugin, status: status) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel([plugin.title, on ? "On" : "Off", source, plugin.summary, status].compactMap { $0 }.joined(separator: ", "))
            PluginSwitch(composer: composer, plugin: plugin, status: status)
        }
        .padding(.horizontal, select == nil ? 14 : 8)
        .padding(.vertical, select == nil ? 6 : 2)
        .background {
            if select != nil && selected {
                RoundedRectangle(cornerRadius: 8).fill(HouseColor.selected)
            }
        }
    }

    private func rowLabel(_ plugin: PluginDescriptor, status: String?) -> some View {
        HStack(spacing: 10) {
            PluginTile(symbol: plugin.symbol, size: select == nil ? 36 : 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.title).font(.body.weight(.semibold))
                if select == nil {
                    Text(plugin.summary).font(.footnote).foregroundStyle(HouseColor.muted)
                        .lineLimit(typeSize > .large ? nil : 1)
                }
                if let status { Text(status).font(.caption).foregroundStyle(HouseColor.muted) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension PluginComposer {
    func statusText(_ plugin: PluginDescriptor, hostRealms: [String]?, realmTitle: (String) -> String) -> String? {
        let global = isEnabled(plugin)
        let realms = hostRealms ?? graph.nodes.filter(\.isContainer).map(\.id)
        let exceptions = realms.filter { hostChoice(for: plugin, in: $0) == (global ? .off : .on) }.map(realmTitle)
        if !exceptions.isEmpty {
            return (global ? "Off for " : "On for ") + exceptions.formatted() + " only"
        }
        let members = members(of: plugin)
        guard let node = trouble(in: members) ?? members.first(where: { $0.phase.kind == .running }) ?? members.first else {
            return nil
        }
        let host = node.container.map { " on " + realmTitle($0) } ?? ""
        return [node.phase.kind.word + host, node.phase.reason].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PluginSwitch: View {
    @ObservedObject var composer: PluginComposer
    let plugin: PluginDescriptor
    let status: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @HouseTracking private var house

    var body: some View {
        let on = composer.isEnabled(plugin)
        let binding = Binding(get: { composer.isEnabled(plugin) }, set: { composer.setEnabled(plugin, $0) })
        Button { binding.wrappedValue.toggle() } label: {
            Capsule()
                .fill(on ? HouseColor.button : HouseColor.faint.opacity(0.45))
                .frame(width: 51, height: 31)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(on ? HouseColor.buttonText : HouseColor.card)
                        .overlay(Circle().strokeBorder(HouseColor.line))
                        .frame(width: 27, height: 27).padding(2)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: on)
        .accessibilityRepresentation {
            let source = composer.effectiveState(for: plugin, in: nil).source.label
            Toggle([plugin.title, source, status].compactMap { $0 }.joined(separator: ", "), isOn: binding)
        }
    }
}

struct PluginCard: View {
    @HouseTracking private var house
    var body: some View {
        RoundedRectangle(cornerRadius: 16).fill(HouseColor.card)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HouseColor.line))
    }
}

struct PluginTile: View {
    let symbol: String
    let size: CGFloat
    @HouseTracking private var house
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.52))
            .foregroundStyle(HouseColor.muted)
            .frame(width: size, height: size)
            .background(HouseColor.fill, in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

struct PluginSectionTitle: View {
    let title: String
    var inset: CGFloat = 14
    @HouseTracking private var house
    var body: some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(HouseColor.muted)
            .padding(.leading, inset).accessibilityAddTraits(.isHeader)
    }
}
