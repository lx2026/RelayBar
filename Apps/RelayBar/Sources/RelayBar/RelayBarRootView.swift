import AppKit
import HouseStyle
import SwiftUI

struct RelayBarRootView: View {
    @HouseTracking private var house
    @EnvironmentObject private var store: TunnelStore
    @State private var screen: Screen = .list
    private let onRemoteFiles: () -> Void
    private let onSettings: () -> Void
    private let serviceLabels: [UUID: ServiceLabel]

    private enum Screen {
        case list
        case editor(Tunnel?)
    }

    init(
        onRemoteFiles: @escaping () -> Void = {},
        onSettings: @escaping () -> Void = {},
        serviceLabels: [UUID: ServiceLabel] = [:]
    ) {
        self.onRemoteFiles = onRemoteFiles
        self.onSettings = onSettings
        self.serviceLabels = serviceLabels
    }

    var body: some View {
        Group {
            switch screen {
            case .list:
                TunnelListView(
                    serviceLabels: serviceLabels,
                    onAdd: { screen = .editor(nil) },
                    onEdit: { screen = .editor($0) },
                    onRemoteFiles: onRemoteFiles,
                    onSettings: onSettings
                )
            case .editor(let tunnel):
                TunnelEditorView(
                    tunnel: tunnel,
                    availableGroups: store.groupNames,
                    onCancel: { screen = .list },
                    onSave: { savedTunnel in
                        if tunnel == nil {
                            store.add(savedTunnel)
                        } else {
                            store.update(savedTunnel)
                        }
                        screen = .list
                    }
                )
            }
        }
        .frame(width: RelayBarPopoverLayout.width, height: RelayBarPopoverLayout.height)
        .foregroundStyle(HouseColor.ink)
        .background(HouseColor.paper)
    }
}

/// What the popover header says after the app name: how many tunnels are active and, when any has
/// failed, how many issues there are.
struct PopoverHeaderSummary: Equatable {
    /// Nil when there are no tunnels.
    let activity: String?
    /// Nil when no tunnel has failed.
    let issues: String?

    init(phases: [TunnelPhase]) {
        if phases.isEmpty {
            activity = nil
        } else {
            let active = phases.count(where: \.isLifecycleActive)
            activity = active == 0 ? "All stopped" : "\(active) active"
        }
        let failed = phases.count { phase in
            if case .failed = phase { return true }
            return false
        }
        issues = switch failed {
        case 0: nil
        case 1: "1 issue"
        default: "\(failed) issues"
        }
    }

    var accessibilityLabel: String {
        var parts = ["RelayBar"]
        if let activity { parts.append(activity == "All stopped" ? "all stopped" : activity) }
        if let issues { parts.append(issues) }
        return parts.joined(separator: ", ")
    }
}

/// The part of a row's second line after its port mapping, and the tooltip that holds its full wording.
struct TunnelRowDetail: Equatable {
    enum Tone: Equatable {
        case secondary
        case warning
        case failure
    }

    let text: String
    let help: String
    /// What VoiceOver reads: everything on screen plus what only the tooltip shows.
    let spokenText: String
    let tone: Tone

    init(phase: TunnelPhase, host: String, serviceLabel: ServiceLabel?) {
        switch phase {
        case .stopped, .running:
            text = serviceLabel.map { "\(host) · \($0.caption)" } ?? host
            help = text
            spokenText = text
            tone = .secondary
        case .starting:
            text = "Connecting…"
            help = text
            spokenText = text
            tone = .secondary
        case .retrying(let attempt, let maxAttempts, let delay, let message):
            let countdown = "Retrying in \(max(1, Int(ceil(delay))))s"
            text = "\(countdown) · attempt \(attempt) of \(maxAttempts)"
            help = "\(countdown) · \(message)"
            spokenText = "\(text) · \(message)"
            tone = .warning
        case .failed(let message):
            text = message
            help = message
            spokenText = message
            tone = .failure
        }
    }
}

/// A tunnel's switch. Its position always follows the tunnel's state. A request that
/// changes nothing, such as a start that fails the same way again, publishes nothing,
/// so the view refreshes itself rather than rely on the control to go back on its own.
struct TunnelSwitch: View {
    let name: String
    let isActive: Bool
    let onToggle: () -> Void

    @State private var requests = 0

    var body: some View {
        let _ = requests
        Toggle(isActive ? "Stop \(name)" : "Start \(name)", isOn: Binding(
            get: { isActive },
            set: {
                guard $0 != isActive else { return }
                onToggle()
                requests &+= 1
            }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .help(isActive ? "Stop profile" : "Start profile")
    }
}

/// The one lifecycle action a named group's header offers.
enum TunnelGroupPrimaryAction: Equatable {
    case startAll
    case stopAll

    var title: String {
        switch self {
        case .startAll: "Start All"
        case .stopAll: "Stop All"
        }
    }

    func label(forGroup name: String) -> String {
        switch self {
        case .startAll: "Start all tunnels in \(name)"
        case .stopAll: "Stop all tunnels in \(name)"
        }
    }
}

#if DEBUG
private struct PreviewHoveredTunnelKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// Draws this tunnel's row as if the pointer were over it, for snapshots.
    var previewHoveredTunnel: UUID? {
        get { self[PreviewHoveredTunnelKey.self] }
        set { self[PreviewHoveredTunnelKey.self] = newValue }
    }
}
#endif

private struct TunnelListView: View {
    @HouseTracking private var house
    @EnvironmentObject private var store: TunnelStore
    let serviceLabels: [UUID: ServiceLabel]
    let onAdd: () -> Void
    let onEdit: (Tunnel) -> Void
    let onRemoteFiles: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            HouseDivider()

            if store.tunnels.isEmpty {
                emptyState
            } else {
                list
            }

            footer
        }
    }

    private var list: some View {
        let grouping = store.grouping

        return PopoverScrollContainer(
            horizontalInset: RelayBarPopoverLayout.listHorizontalInset,
            topInset: RelayBarPopoverLayout.listTopInset,
            bottomInset: RelayBarPopoverLayout.listBottomInset
        ) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if grouping.isGrouped {
                    ForEach(grouping.sections) { section in
                        VStack(spacing: 0) {
                            groupHeader(section, availableGroups: grouping.groupNames)
                                .padding(
                                    .top,
                                    section.id == grouping.sections.first?.id
                                        ? 0 : RelayBarPopoverLayout.groupSpacing
                                )
                            ForEach(section.tunnels) { tunnel in
                                tunnelRow(tunnel, availableGroups: grouping.groupNames)
                            }
                        }
                    }
                } else {
                    ForEach(store.tunnels) { tunnel in
                        tunnelRow(tunnel, availableGroups: grouping.groupNames)
                    }
                }
            }
        }
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: RelayBarPopoverLayout.listBottomInset)
            }
        }
    }

    @ViewBuilder
    private func groupHeader(
        _ section: TunnelGroupSection,
        availableGroups: [String]
    ) -> some View {
        if let name = section.name {
            let availability = TunnelGroupActionAvailability(
                phases: section.tunnels.map { store.phase(for: $0) }
            )
            TunnelGroupHeader(
                name: name,
                availableGroups: availableGroups,
                availability: availability,
                onStartAll: { store.startGroup(name) },
                onStopAll: { store.stopGroup(name) },
                onRestartAll: { store.restartGroup(name) },
                onRename: { store.renameGroup(name, to: $0) },
                onUngroupAll: { store.ungroup(name) }
            )
        } else {
            Text(section.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HouseColor.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, RelayBarPopoverLayout.rowLeadingInset)
                .padding(.trailing, RelayBarPopoverLayout.rowTrailingInset)
                .frame(height: RelayBarPopoverLayout.groupHeaderHeight)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func tunnelRow(
        _ tunnel: Tunnel,
        availableGroups: [String]
    ) -> some View {
        TunnelRow(
            tunnel: tunnel,
            phase: store.phase(for: tunnel),
            runtimePorts: store.runtimePorts(for: tunnel),
            serviceLabels: serviceLabels,
            availableGroups: availableGroups,
            onToggle: { store.toggle(tunnel) },
            onOpen: { store.openInBrowser(tunnel) },
            onOpenRule: {
                store.openInBrowser(tunnel, ruleID: $0)
            },
            onEdit: { onEdit(tunnel) },
            onMoveToGroup: { store.move(tunnel, toGroup: $0) },
            onDelete: { store.delete(tunnel) }
        )
    }

    private var header: some View {
        let summary = PopoverHeaderSummary(phases: store.tunnels.map { store.phase(for: $0) })

        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("RelayBar")
                    .font(.system(size: 13, weight: .semibold))
                if let activity = summary.activity {
                    Text(activity)
                        .font(.system(size: 12))
                        .foregroundStyle(HouseColor.muted)
                }
                if let issues = summary.issues {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(issues)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(HouseColor.failure)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.accessibilityLabel)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .help("Add tunnel")
            .accessibilityLabel("Add tunnel")
        }
        .buttonStyle(PopoverIconButtonStyle())
        .padding(.leading, RelayBarPopoverLayout.headerTitleInset)
        .padding(.trailing, RelayBarPopoverLayout.headerButtonInset)
        .frame(height: RelayBarPopoverLayout.headerHeight)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.09))
                    .frame(width: 64, height: 64)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 4) {
                Text("Your shortcuts to anywhere")
                    .font(.title3.weight(.semibold))
                Text("Paste an SSH command or add a tunnel by hand.")
                    .font(.callout)
                    .foregroundStyle(HouseColor.muted)
            }

            Button("Add your first tunnel", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// Forty points including the hairline above it.
    private var footer: some View {
        VStack(spacing: 0) {
            HouseDivider()
            footerActions
                .frame(maxHeight: .infinity)
        }
        .frame(height: RelayBarPopoverLayout.footerHeight)
    }

    private var footerActions: some View {
        HStack(spacing: 0) {
            Button(action: onRemoteFiles) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .frame(width: 16, height: 16)
                    Text("Remote Files…")
                }
            }
            .buttonStyle(PopoverTextButtonStyle())
            .help("Open a folder on a saved SSH server")
            .accessibilityHint("Opens the Remote Files window")

            Spacer(minLength: 0)

            Button("Quit") { store.quit() }
                .buttonStyle(PopoverTextButtonStyle(tint: HouseColor.muted))
        }
        .padding(.horizontal, RelayBarPopoverLayout.footerInset)
    }
}

private struct TunnelRow: View {
    @HouseTracking private var house
    let tunnel: Tunnel
    let phase: TunnelPhase
    let runtimePorts: [UUID: Int]
    /// Labels from Service Labels, keyed by rule id; empty while it is off.
    let serviceLabels: [UUID: ServiceLabel]
    let availableGroups: [String]
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onOpenRule: (UUID) -> Void
    let onEdit: () -> Void
    let onMoveToGroup: (String?) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isNamingNewGroup = false
    @FocusState private var focusedControl: Control?
    #if DEBUG
    @Environment(\.previewHoveredTunnel) private var previewHoveredTunnel
    #endif

    private enum Control: Hashable {
        case open
        case menu
        case toggle
    }

    private static let actionSpacing: CGFloat = 2
    /// The actions sit this much closer to the switch than the row's spacing.
    private static let actionTrailingOverlap: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            line

            if isNamingNewGroup {
                InlineGroupNameEditor(
                    initialValue: "",
                    placeholder: "New group name",
                    availableGroups: availableGroups,
                    commitAccessibilityLabel: "Create group for \(tunnel.displayName)",
                    onCommit: {
                        onMoveToGroup($0)
                        isNamingNewGroup = false
                    },
                    onCancel: {
                        isNamingNewGroup = false
                    }
                )
                .padding(.leading, RelayBarPopoverLayout.rowLeadingInset
                    + RelayBarPopoverLayout.statusColumnWidth + RelayBarPopoverLayout.rowSpacing)
                .padding(.trailing, RelayBarPopoverLayout.rowTrailingInset)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: RelayBarPopoverLayout.rowCornerRadius, style: .continuous)
                .fill(isHighlighted || isNamingNewGroup
                    ? HouseColor.fill : .clear)
        )
        .onHover { isHovered = $0 }
        .clearingHoverWhenWindowResignsKey($isHovered)
    }

    private var line: some View {
        HStack(spacing: RelayBarPopoverLayout.rowSpacing) {
            TunnelStatusGlyph(phase: phase)

            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                secondLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Revealed actions take space from the text; hidden ones stay in
            // place, invisible, so keyboard focus and VoiceOver still reach them.
            .padding(.trailing, isRevealed ? actionsWidth + RelayBarPopoverLayout.rowSpacing
                - Self.actionTrailingOverlap : 0)
            .overlay(alignment: .trailing) {
                actions
                    .offset(x: Self.actionTrailingOverlap)
                    .opacity(isRevealed ? 1 : 0.001)
            }

            TunnelSwitch(name: tunnel.displayName, isActive: isActive, onToggle: onToggle)
                .focused($focusedControl, equals: .toggle)
        }
        .padding(.leading, RelayBarPopoverLayout.rowLeadingInset)
        .padding(.trailing, RelayBarPopoverLayout.rowTrailingInset)
        .frame(height: RelayBarPopoverLayout.rowHeight)
        .contentShape(Rectangle())
        .contextMenu { rowMenu }
    }

    private var secondLine: some View {
        let detail = TunnelRowDetail(phase: phase, host: tunnel.sshHost, serviceLabel: browserLabel)
        let fullSummary = tunnel.displaySummary(runtimePorts: runtimePorts)

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(tunnel.compactDisplaySummary(runtimePorts: runtimePorts))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(HouseColor.muted)
                // Equal priority: a long mapping gives up its middle rather
                // than squeezing the host or the status text down to nothing.
                .truncationMode(.middle)
                .help(fullSummary)
                .accessibilityLabel(fullSummary)
            Text(" · " + detail.text)
                .font(.system(size: 11))
                .foregroundStyle(color(for: detail.tone))
                .truncationMode(.tail)
                .help(detail.help)
                .accessibilityLabel(detail.spokenText)
        }
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: Self.actionSpacing) {
            if tunnel.unambiguousBrowserURL != nil {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(PopoverIconButtonStyle.row())
                .help(openButtonHelp)
                .accessibilityLabel("Open \(tunnel.displayName) in browser")
                .focused($focusedControl, equals: .open)
            }

            Menu {
                rowMenu
            } label: {
                Image(systemName: "ellipsis")
            }
            .popoverIconMenu()
            .help("More actions for \(tunnel.displayName)")
            .accessibilityLabel("More actions for \(tunnel.displayName)")
            .focused($focusedControl, equals: .menu)
        }
    }

    private var actionsWidth: CGFloat {
        let size = RelayBarPopoverLayout.rowIconButtonSize
        return tunnel.unambiguousBrowserURL == nil ? size : size * 2 + Self.actionSpacing
    }

    @ViewBuilder
    private var rowMenu: some View {
        ForEach(Array(tunnel.rules.enumerated()), id: \.element.id) { index, rule in
            Menu(ruleMenuTitle(rule, index: index)) {
                if rule.localBrowserURL != nil {
                    Button("Open in Browser", systemImage: "safari") {
                        onOpenRule(rule.id)
                    }
                }

                if let endpoint = rule.copyableListenEndpoint(
                    runtimePort: runtimePorts[rule.id]
                ) {
                    Button("Copy \(copyLabel(for: rule))", systemImage: "doc.on.doc") {
                        copy(endpoint)
                    }
                } else if rule.listen.tcp?.port == 0 {
                    Button("Allocated port available while running") {}
                        .disabled(true)
                }

                if
                    rule.kind == .remoteDynamic,
                    let policy = tunnel.reverseSOCKSPolicy
                {
                    Button("Destinations: \(policy.displayText)") {}
                        .disabled(true)
                }

                // Offered from the rule's shape alone. Probing the
                // filesystem here would put a stat in a body that
                // re-evaluates on every phase change.
                if let path = rule.createdLocalSocketPath {
                    Button("Reveal Local Socket", systemImage: "finder") {
                        revealSocket(at: path)
                    }
                }
            }
        }
        Divider()
        Menu("Move to Group") {
            Button {
                onMoveToGroup(nil)
            } label: {
                groupChoiceLabel(
                    "Ungrouped",
                    isSelected: tunnel.groupTag == nil
                )
            }
            ForEach(availableGroups, id: \.self) { group in
                Button {
                    onMoveToGroup(group)
                } label: {
                    groupChoiceLabel(
                        group,
                        isSelected: isCurrentGroup(group)
                    )
                }
            }
            Divider()
            Button("New Group…") {
                isNamingNewGroup = true
            }
        }
        Button("Edit", systemImage: "pencil", action: onEdit)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }

    /// Under the pointer, or drawn so for a snapshot.
    private var isHighlighted: Bool {
        #if DEBUG
        if previewHoveredTunnel == tunnel.id { return true }
        #endif
        return isHovered
    }

    private var isRevealed: Bool {
        isHighlighted || focusedControl != nil
    }

    private var isActive: Bool {
        phase.isLifecycleActive
    }

    private func color(for tone: TunnelRowDetail.Tone) -> Color {
        switch tone {
        case .secondary: HouseColor.muted
        case .warning: HouseColor.warning
        case .failure: HouseColor.failure
        }
    }

    private var openButtonHelp: String {
        switch phase {
        case .running:
            return "Open in browser"
        case .starting, .retrying:
            return "Open in browser when connected"
        case .stopped, .failed:
            return "Start tunnel and open in browser"
        }
    }

    /// The label of the rule the browser button opens, when Service Labels has one.
    private var browserLabel: ServiceLabel? {
        guard tunnel.unambiguousBrowserURL != nil, let rule = tunnel.rules.first else { return nil }
        return serviceLabels[rule.id]
    }

    private func ruleMenuTitle(_ rule: ForwardingRule, index: Int) -> String {
        let title = "Rule \(index + 1) · \(rule.kind.label)"
        guard let name = serviceLabels[rule.id]?.name else { return title }
        return "\(title) · \(name)"
    }

    private func isCurrentGroup(_ group: String) -> Bool {
        guard let current = tunnel.groupTag else { return false }
        return TunnelGroupTag.canonicalKey(current)
            == TunnelGroupTag.canonicalKey(group)
    }

    @ViewBuilder
    private func groupChoiceLabel(
        _ title: String,
        isSelected: Bool
    ) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func copyLabel(for rule: ForwardingRule) -> String {
        switch rule.listen.kind {
        case .unix:
            return "Socket Path"
        case .tcp:
            return rule.kind.isDynamic ? "SOCKS Endpoint" : "Listen Endpoint"
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Falls back to the enclosing folder when the socket is gone, so a stale
    /// menu item still lands somewhere useful instead of doing nothing.
    private func revealSocket(at path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(
                [url.deletingLastPathComponent()]
            )
        }
    }
}

/// A row's status, told apart by shape as well as colour.
private struct TunnelStatusGlyph: View {
    @HouseTracking private var house
    let phase: TunnelPhase

    var body: some View {
        Group {
            switch phase {
            case .stopped:
                Circle()
                    .strokeBorder(HouseColor.faint, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            case .running:
                Circle()
                    .fill(HouseColor.running)
                    .frame(width: 8, height: 8)
            case .starting:
                ProgressArc(color: HouseColor.muted)
            case .retrying:
                ProgressArc(color: HouseColor.retrying)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(HouseColor.failure)
            }
        }
        .frame(width: RelayBarPopoverLayout.statusColumnWidth, height: RelayBarPopoverLayout.statusColumnWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusName)
    }

    private var statusName: String {
        switch phase {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .retrying: "Retrying"
        case .running: "Running"
        case .failed: "Failed"
        }
    }
}

/// An open ring that turns while the tunnel connects; still under Reduce Motion.
private struct ProgressArc: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTurning = false

    var body: some View {
        Circle()
            .inset(by: 1)
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            // The gap faces the trailing side at rest.
            .rotationEffect(.degrees(45 + (isTurning ? 360 : 0)))
            .animation(
                isTurning ? .linear(duration: 1).repeatForever(autoreverses: false) : nil,
                value: isTurning
            )
            .frame(width: 10, height: 10)
            .onAppear { isTurning = !reduceMotion }
            .onChange(of: reduceMotion) { isTurning = !$0 }
    }
}

private struct TunnelGroupHeader: View {
    @HouseTracking private var house
    let name: String
    let availableGroups: [String]
    let availability: TunnelGroupActionAvailability
    let onStartAll: () -> Void
    let onStopAll: () -> Void
    let onRestartAll: () -> Void
    let onRename: (String) -> Void
    let onUngroupAll: () -> Void

    @State private var isHovered = false
    @State private var isRenaming = false
    @FocusState private var isMenuFocused: Bool

    var body: some View {
        Group {
            if isRenaming {
                InlineGroupNameEditor(
                    initialValue: name,
                    placeholder: "Group name",
                    availableGroups: availableGroups,
                    commitAccessibilityLabel: "Rename \(name) group",
                    onCommit: {
                        onRename($0)
                        isRenaming = false
                    },
                    onCancel: {
                        isRenaming = false
                    }
                )
                .padding(.leading, RelayBarPopoverLayout.rowLeadingInset)
                .padding(.trailing, RelayBarPopoverLayout.rowTrailingInset)
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HouseColor.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)

                    Spacer(minLength: 0)

                    Menu {
                        groupMenuActions
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .popoverIconMenu(style: .row(tint: HouseColor.muted))
                    .opacity(isHovered || isMenuFocused ? 1 : 0.001)
                    .focused($isMenuFocused)
                    .accessibilityLabel("\(name) group actions")

                    let action = availability.primaryAction
                    Button {
                        switch action {
                        case .startAll: onStartAll()
                        case .stopAll: onStopAll()
                        }
                    } label: {
                        Text(action.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: RelayBarPopoverPalette.accentText))
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(!availability.isPrimaryActionAvailable)
                    .help(action.label(forGroup: name))
                    .accessibilityLabel(action.label(forGroup: name))
                }
                .padding(.leading, RelayBarPopoverLayout.rowLeadingInset)
                .padding(.trailing, RelayBarPopoverLayout.rowTrailingInset)
                .frame(height: RelayBarPopoverLayout.groupHeaderHeight)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .clearingHoverWhenWindowResignsKey($isHovered)
                .contextMenu {
                    groupMenuActions
                }
            }
        }
    }

    @ViewBuilder
    private var groupMenuActions: some View {
        // The header shows only one of these; a group with some members
        // running and some stopped still needs both.
        Button("Start All", systemImage: "play.fill") {
            onStartAll()
        }
        .disabled(!availability.canStartAll)
        .accessibilityLabel("Start all tunnels in \(name)")
        Button("Stop All", systemImage: "stop.fill") {
            onStopAll()
        }
        .disabled(!availability.canStopAll)
        .accessibilityLabel("Stop all tunnels in \(name)")
        Button("Restart All", systemImage: "arrow.clockwise") {
            onRestartAll()
        }
        .disabled(!availability.canRestartAll)
        .accessibilityLabel("Restart all tunnels in \(name)")
        Divider()
        Button("Rename Group…", systemImage: "pencil") {
            isRenaming = true
        }
        Button("Ungroup All", systemImage: "rectangle.3.group") {
            onUngroupAll()
        }
    }
}

struct TunnelGroupActionAvailability: Equatable {
    let canStartAll: Bool
    let canStopAll: Bool

    var canRestartAll: Bool { canStopAll }

    /// Stop All while any member is starting, retrying or running; otherwise Start All.
    var primaryAction: TunnelGroupPrimaryAction { canStopAll ? .stopAll : .startAll }

    var isPrimaryActionAvailable: Bool {
        switch primaryAction {
        case .startAll: canStartAll
        case .stopAll: canStopAll
        }
    }

    init(phases: [TunnelPhase]) {
        canStartAll = phases.contains { !$0.isLifecycleActive }
        canStopAll = phases.contains(where: \.isLifecycleActive)
    }
}

private struct InlineGroupNameEditor: View {
    @HouseTracking private var house
    let placeholder: String
    let availableGroups: [String]
    let commitAccessibilityLabel: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draftName: String
    @State private var validationMessage: String?
    @FocusState private var isFocused: Bool

    init(
        initialValue: String,
        placeholder: String,
        availableGroups: [String],
        commitAccessibilityLabel: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self.availableGroups = availableGroups
        self.commitAccessibilityLabel = commitAccessibilityLabel
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draftName = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: draftName) { _ in
                        validationMessage = nil
                    }

                Button(action: commit) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderless)
                .help("Save group name")
                .accessibilityLabel(commitAccessibilityLabel)

                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel")
                .accessibilityLabel("Cancel group name")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.subheadline)
                    .foregroundStyle(HouseColor.failure)
            }
        }
        .onAppear {
            isFocused = true
        }
    }

    private func commit() {
        switch TunnelGroupTag.resolve(
            draftName,
            existingNames: availableGroups
        ) {
        case .ungrouped:
            validationMessage = "Enter a group name."
        case .invalid(let message):
            validationMessage = message
        case .valid(let normalized):
            onCommit(normalized)
        }
    }

    private func cancel() {
        validationMessage = nil
        onCancel()
    }
}
