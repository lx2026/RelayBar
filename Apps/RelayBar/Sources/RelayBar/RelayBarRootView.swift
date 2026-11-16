import AppKit
import SwiftUI

struct RelayBarRootView: View {
    @EnvironmentObject private var store: TunnelStore
    @ObservedObject private var launchAtLogin: LaunchAtLoginModel
    @ObservedObject private var updates: UpdateModel
    @State private var screen: Screen = .list
    private let onRemoteFiles: () -> Void
    private let onRevokeFrame: () -> Void
    private let composition: RelayBarComposition?
    private let serviceLabels: [UUID: ServiceLabel]

    private enum Screen {
        case list
        case editor(Tunnel?)
        case settings
    }

    init(
        loginItemService: any LoginItemServicing = MainAppLoginItemService(),
        updateModel: UpdateModel,
        loginModel: LaunchAtLoginModel? = nil,
        onRemoteFiles: @escaping () -> Void = {},
        onRevokeFrame: @escaping () -> Void = {},
        serviceLabels: [UUID: ServiceLabel] = [:],
        composition: RelayBarComposition? = nil
    ) {
        launchAtLogin = loginModel ?? LaunchAtLoginModel(service: loginItemService)
        updates = updateModel
        self.onRemoteFiles = onRemoteFiles; self.onRevokeFrame = onRevokeFrame
        self.serviceLabels = serviceLabels
        self.composition = composition
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
                    onSettings: { screen = .settings }
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
            case .settings:
                SettingsView(
                    store: store,
                    launchAtLogin: launchAtLogin,
                    updates: updates,
                    composition: composition,
                    onRevokeFrame: onRevokeFrame,
                    onBack: { screen = .list }
                )
            }
        }
        .frame(width: 380, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TunnelListView: View {
    @EnvironmentObject private var store: TunnelStore
    let serviceLabels: [UUID: ServiceLabel]
    let onAdd: () -> Void
    let onEdit: (Tunnel) -> Void
    let onRemoteFiles: () -> Void
    let onSettings: () -> Void

    var body: some View {
        let grouping = store.grouping

        VStack(spacing: 0) {
            header
            Divider()

            if store.tunnels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: grouping.isGrouped ? 16 : 8) {
                        if grouping.isGrouped {
                            ForEach(grouping.sections) { section in
                                VStack(spacing: 8) {
                                    groupHeader(
                                        section,
                                        availableGroups: grouping.groupNames
                                    )
                                    ForEach(section.tunnels) { tunnel in
                                        tunnelRow(
                                            tunnel,
                                            availableGroups: grouping.groupNames
                                        )
                                    }
                                }
                            }
                        } else {
                            ForEach(store.tunnels) { tunnel in
                                tunnelRow(
                                    tunnel,
                                    availableGroups: grouping.groupNames
                                )
                            }
                        }
                    }
                    .padding(RelayBarPopoverLayout.contentInset)
                }
            }

            Divider()
            remoteFilesAction
            Divider()
            footer
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
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
        HStack(spacing: 12) {
            AppMark(size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("RelayBar")
                    .font(.title3.weight(.semibold))
                Text(activityText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")

                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .help("Add tunnel")
                .accessibilityLabel("Add tunnel")
            }
            .buttonStyle(PopoverIconButtonStyle())
        }
        .padding(.horizontal, RelayBarPopoverLayout.contentInset)
        .frame(minHeight: RelayBarPopoverLayout.headerHeight)
    }

    private var activityText: String {
        switch store.runningCount {
        case 0: return store.tunnels.isEmpty ? "Simple SSH tunnels" : "All tunnels stopped"
        case 1: return "1 tunnel active"
        default: return "\(store.runningCount) tunnels active"
        }
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
                    .foregroundStyle(.secondary)
            }

            Button("Add your first tunnel", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Label("Uses macOS SSH", systemImage: "lock.shield")
            Spacer()
            Button("Quit") { store.quit() }
                .buttonStyle(.plain)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, RelayBarPopoverLayout.contentInset)
        .frame(minHeight: 36)
    }

    private var remoteFilesAction: some View {
        Button(action: onRemoteFiles) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
                Text("Remote Files…")
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.weight(.medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RelayBarPopoverLayout.contentInset)
        .frame(minHeight: 36)
        .help("Open a folder on a saved SSH server")
        .accessibilityHint("Opens the Remote Files window")
    }
}

private struct TunnelRow: View {
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

    @State private var isNamingNewGroup = false

    var body: some View {
        VStack(spacing: 8) {
            // One spacing for text and controls keeps the button columns
            // aligned with the group header's controls.
            HStack(spacing: 8) {
                statusIndicator

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(tunnel.displayName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if case .failed = phase {
                            statusBadge("Issue", color: .red)
                        } else if case .retrying(let attempt, let maxAttempts, _, _) = phase {
                            statusBadge("Retry \(attempt)/\(maxAttempts)", color: .orange)
                        }
                    }

                    Text(tunnel.compactDisplaySummary(runtimePorts: runtimePorts))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(tunnel.displaySummary(runtimePorts: runtimePorts))
                        .accessibilityLabel(tunnel.displaySummary(runtimePorts: runtimePorts))

                    Text(errorOrHost)
                        .font(.subheadline)
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if tunnel.unambiguousBrowserURL != nil {
                    Button(action: onOpen) {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(PopoverIconButtonStyle(isEmphasized: phase == .running))
                    .help(openButtonHelp)
                    .accessibilityLabel("Open \(tunnel.displayName) in browser")
                }

                Menu {
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
                } label: {
                    Image(systemName: "ellipsis")
                }
                .popoverIconMenu()

                // Start is what a stopped or failed profile most likely needs;
                // once it runs, Open in Browser takes the emphasis instead.
                Button(action: onToggle) {
                    toggleIcon
                }
                .buttonStyle(PopoverIconButtonStyle(isEmphasized: !isActive))
                .help(isActive ? "Stop profile" : "Start profile")
                .accessibilityLabel(
                    isActive ? "Stop \(tunnel.displayName)" : "Start \(tunnel.displayName)"
                )
            }

            if isNamingNewGroup {
                Divider()
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
            }
        }
        .padding(12)
        .popoverCard()
    }

    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.1)))
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .shadow(color: statusColor.opacity(isActive ? 0.45 : 0), radius: 3)
    }

    @ViewBuilder private var toggleIcon: some View {
        if showsProgress {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        } else {
            Image(systemName: isActive ? "stop.fill" : "play.fill")
                .imageScale(.small)
                .offset(x: isActive ? 0 : 1)
        }
    }

    private var isActive: Bool {
        phase.isLifecycleActive
    }

    private var showsProgress: Bool {
        switch phase {
        case .starting, .retrying:
            return true
        case .stopped, .running, .failed:
            return false
        }
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var statusColor: Color {
        switch phase {
        case .running: return .green
        case .starting, .retrying: return .orange
        case .failed: return .red
        case .stopped: return Color.secondary.opacity(0.45)
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

    private var errorOrHost: String {
        switch phase {
        case .failed(let message):
            return message
        case .retrying(_, _, let delay, let message):
            return "Retrying in \(max(1, Int(ceil(delay))))s · \(message)"
        case .stopped, .starting, .running:
            guard let browserLabel else { return "via \(tunnel.sshHost)" }
            return "via \(tunnel.sshHost) · \(browserLabel.caption)"
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

private struct TunnelGroupHeader: View {
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
            } else {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)

                    Spacer(minLength: 0)

                    groupLifecycleControls

                    Menu {
                        groupMenuActions
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .popoverIconMenu()
                    .opacity(isHovered || isMenuFocused ? 1 : 0.001)
                    .focused($isMenuFocused)
                    .accessibilityLabel("\(name) group actions")
                }
                // Matches the row card's inset so the controls line up
                // with the rows' button columns.
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .contextMenu {
                    groupMenuActions
                }
            }
        }
    }

    @ViewBuilder
    private var groupLifecycleControls: some View {
        HStack(spacing: 8) {
            Button {
                onStartAll()
            } label: {
                Image(systemName: "play.fill")
                    .imageScale(.small)
                    .offset(x: 1)
            }
            .disabled(!availability.canStartAll)
            .help("Start all tunnels in \(name)")
            .accessibilityLabel("Start all tunnels in \(name)")

            Button {
                onStopAll()
            } label: {
                Image(systemName: "stop.fill")
                    .imageScale(.small)
            }
            .disabled(!availability.canStopAll)
            .help("Stop all tunnels in \(name)")
            .accessibilityLabel("Stop all tunnels in \(name)")
        }
        .buttonStyle(PopoverIconButtonStyle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var groupMenuActions: some View {
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

    init(phases: [TunnelPhase]) {
        canStartAll = phases.contains { !$0.isLifecycleActive }
        canStopAll = phases.contains(where: \.isLifecycleActive)
    }
}

private struct InlineGroupNameEditor: View {
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
                    .foregroundStyle(.red)
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

private struct AppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.50, blue: 0.98), Color(red: 0.16, green: 0.72, blue: 0.82)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
