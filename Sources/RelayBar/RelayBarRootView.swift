import AppKit
import SwiftUI

struct RelayBarRootView: View {
    @EnvironmentObject private var store: TunnelStore
    @State private var screen: Screen = .list

    private enum Screen {
        case list
        case editor(Tunnel?)
    }

    var body: some View {
        Group {
            switch screen {
            case .list:
                TunnelListView(
                    onAdd: { screen = .editor(nil) },
                    onEdit: { screen = .editor($0) },
                    onRemoteFiles: {
                        RemoteFilesWindowController.shared.show(tunnels: store.tunnels)
                    }
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
        .frame(width: 380, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TunnelListView: View {
    @EnvironmentObject private var store: TunnelStore
    let onAdd: () -> Void
    let onEdit: (Tunnel) -> Void
    let onRemoteFiles: () -> Void

    var body: some View {
        let grouping = store.grouping

        VStack(spacing: 0) {
            header
            Divider()

            if store.tunnels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: grouping.isGrouped ? 14 : 9) {
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
                    .padding(12)
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
            TunnelGroupHeader(
                name: name,
                availableGroups: availableGroups,
                onRename: { store.renameGroup(name, to: $0) },
                onUngroupAll: { store.ungroup(name) }
            )
        } else {
            Text(section.displayName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
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
        HStack(spacing: 11) {
            AppMark(size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("RelayBar")
                    .font(.system(size: 15, weight: .semibold))
                Text(activityText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Add tunnel")
            .accessibilityLabel("Add tunnel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var activityText: String {
        switch store.runningCount {
        case 0: return store.tunnels.isEmpty ? "Simple SSH tunnels" : "All tunnels stopped"
        case 1: return "1 tunnel active"
        default: return "\(store.runningCount) tunnels active"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.09))
                    .frame(width: 66, height: 66)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 5) {
                Text("Your shortcuts to anywhere")
                    .font(.system(size: 15, weight: .semibold))
                Text("Paste an SSH command or add a tunnel by hand.")
                    .font(.system(size: 12))
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
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { store.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private var remoteFilesAction: some View {
        Button(action: onRemoteFiles) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Remote Files…")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .help("Open a folder on a saved SSH server")
        .accessibilityHint("Opens the Remote Files window")
    }
}

private struct TunnelRow: View {
    let tunnel: Tunnel
    let phase: TunnelPhase
    let runtimePorts: [UUID: Int]
    let availableGroups: [String]
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onOpenRule: (UUID) -> Void
    let onEdit: () -> Void
    let onMoveToGroup: (String?) -> Void
    let onDelete: () -> Void

    @State private var isNamingNewGroup = false

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 11) {
                statusIndicator

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(tunnel.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        if case .failed = phase {
                            Text("Issue")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.1)))
                        } else if case .retrying(let attempt, let maxAttempts, _, _) = phase {
                            Text("Retry \(attempt)/\(maxAttempts)")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.1)))
                        }
                    }

                    Text(tunnel.displaySummary(runtimePorts: runtimePorts))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(errorOrHost)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if tunnel.unambiguousBrowserURL != nil {
                    Button(action: onOpen) {
                        Image(systemName: "safari")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.accentColor.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help(openButtonHelp)
                    .accessibilityLabel("Open \(tunnel.displayName) in browser")
                }

                Menu {
                    ForEach(Array(tunnel.rules.enumerated()), id: \.element.id) { index, rule in
                        Menu("Rule \(index + 1) · \(rule.kind.label)") {
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
                        .frame(width: 25, height: 25)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button(action: onToggle) {
                    ZStack {
                        Circle()
                            .fill(toggleFill)
                            .frame(width: 32, height: 32)
                        toggleIcon
                    }
                }
                .buttonStyle(.plain)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
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
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.72))
                .offset(x: isActive ? 0 : 1)
        }
    }

    private var isActive: Bool {
        switch phase {
        case .starting, .retrying, .running:
            return true
        case .stopped, .failed:
            return false
        }
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

    private var toggleFill: Color {
        isActive ? Color.accentColor : Color.primary.opacity(0.07)
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
            return "via \(tunnel.sshHost)"
        }
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
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)

                    Menu {
                        groupActions
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .opacity(isHovered || isMenuFocused ? 1 : 0.001)
                    .focused($isMenuFocused)
                    .accessibilityLabel("\(name) group actions")
                }
                .padding(.leading, 4)
                .padding(.trailing, 2)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .contextMenu {
                    groupActions
                }
            }
        }
    }

    @ViewBuilder
    private var groupActions: some View {
        Button("Rename Group…", systemImage: "pencil") {
            isRenaming = true
        }
        Button("Ungroup All", systemImage: "rectangle.3.group") {
            onUngroupAll()
        }
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
                    .font(.system(size: 11.5))
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
                    .font(.system(size: 10))
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
