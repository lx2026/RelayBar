import SwiftUI

struct TunnelEditorView: View {
    let tunnel: Tunnel?
    let availableGroups: [String]
    let onCancel: () -> Void
    let onSave: (Tunnel) -> Void

    @State private var name: String
    @State private var groupTag: String?
    @State private var sshHost: String
    @State private var command = ""
    @State private var rules: [ForwardingRuleDraft]
    @State private var additionalArguments: [String]
    @State private var reversePolicyChoice: ReversePolicyChoice
    @State private var reverseAllowedDestinations: String
    @State private var streamBindMask: String
    @State private var unlinkStaleSocket: Bool
    @State private var importError: String?
    @State private var hasPendingGroupName = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case command
        case name
        case sshHost
    }

    init(
        tunnel: Tunnel?,
        availableGroups: [String],
        onCancel: @escaping () -> Void,
        onSave: @escaping (Tunnel) -> Void
    ) {
        self.tunnel = tunnel
        self.availableGroups = availableGroups
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: tunnel?.name ?? "")
        _groupTag = State(initialValue: tunnel?.groupTag)
        _sshHost = State(initialValue: tunnel?.sshHost ?? "")
        _rules = State(
            initialValue: tunnel?.rules.map(ForwardingRuleDraft.init)
                ?? [ForwardingRuleDraft(kind: .local)]
        )
        _additionalArguments = State(initialValue: tunnel?.additionalArguments ?? [])

        switch tunnel?.reverseSOCKSPolicy {
        case .some(.any):
            _reversePolicyChoice = State(initialValue: .any)
            _reverseAllowedDestinations = State(initialValue: "")
        case .some(.none):
            _reversePolicyChoice = State(initialValue: .none)
            _reverseAllowedDestinations = State(initialValue: "")
        case .some(.allow(let destinations)):
            _reversePolicyChoice = State(initialValue: .restricted)
            _reverseAllowedDestinations = State(
                initialValue: destinations.joined(separator: "\n")
            )
        case nil:
            _reversePolicyChoice = State(initialValue: .unspecified)
            _reverseAllowedDestinations = State(initialValue: "")
        }

        _streamBindMask = State(
            initialValue: tunnel?.streamLocalSettings.bindMaskArgument ?? "0177"
        )
        _unlinkStaleSocket = State(
            initialValue: tunnel?.streamLocalSettings.unlinkStaleSocket ?? false
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    if tunnel == nil { quickImport }
                    connectionDetails
                    forwardingRules
                    if hasReverseSOCKS { reverseSOCKSSettings }
                    if usesUnixSockets { unixSocketSettings }
                    safetyMessages
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            actionBar
        }
        .onAppear {
            focusedField = tunnel == nil ? .command : .name
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text(tunnel == nil ? "New Profile" : "Edit Profile")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var quickImport: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("QUICK ADD")

            HStack(spacing: 7) {
                TextField(
                    "ssh -N -L 8080:localhost:3000 -D 1080 user@host",
                    text: $command
                )
                .accessibilityLabel("SSH command")
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(minWidth: 0)
                .layoutPriority(1)
                .focused($focusedField, equals: .command)
                .onSubmit(importCommand)

                Button("Import", action: importCommand)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            } else {
                Text("Paste a forwarding-only SSH command. All -L, -D, and -R rules are imported.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.14), lineWidth: 1)
        )
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionLabel("CONNECTION")

            EditorField(label: "Name", hint: "Optional") {
                TextField("Development access", text: $name)
                    .focused($focusedField, equals: .name)
            }

            GroupSelectionControl(
                selection: $groupTag,
                hasPendingName: $hasPendingGroupName,
                availableGroups: availableGroups
            )

            EditorField(label: "SSH host", hint: "user@server") {
                TextField("user@bastion.example.com", text: $sshHost)
                    .focused($focusedField, equals: .sshHost)
            }

            if !additionalArguments.isEmpty {
                Label(
                    "\(additionalArguments.count) imported SSH option values will be preserved.",
                    systemImage: "checkmark.circle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var forwardingRules: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("FORWARDING RULES")
                Spacer()
                Menu {
                    ForEach(ForwardingRuleKind.allCases, id: \.self) { kind in
                        Button(kind.label) {
                            rules.append(ForwardingRuleDraft(kind: kind))
                            if kind == .remoteDynamic {
                                reversePolicyChoice = .unspecified
                            }
                        }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Add forwarding rule")
            }

            ForEach($rules) { $rule in
                ForwardingRuleEditor(
                    draft: $rule,
                    position: rulePosition(rule.id),
                    count: rules.count,
                    onMoveUp: { moveRule(rule.id, offset: -1) },
                    onMoveDown: { moveRule(rule.id, offset: 1) },
                    onDuplicate: { duplicateRule(rule.id) },
                    onDelete: { deleteRule(rule.id) }
                )
            }

            if rules.isEmpty {
                Label(
                    "Add at least one forwarding rule.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
            }
        }
    }

    private var reverseSOCKSSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("REMOTE SOCKS DESTINATIONS")

            Picker("Allowed destinations", selection: $reversePolicyChoice) {
                ForEach(ReversePolicyChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)

            if reversePolicyChoice == .restricted {
                EditorField(label: "Allowlist", hint: "One host:port per line") {
                    TextEditor(text: $reverseAllowedDestinations)
                        .accessibilityLabel("Remote SOCKS allowed destinations")
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(minHeight: 54)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                }
            }

            Text(
                "Remote SOCKS lets clients on the SSH-server side open TCP connections from this Mac’s network position."
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.07))
        )
    }

    private var unixSocketSettings: some View {
        DisclosureGroup("Unix socket options") {
            VStack(alignment: .leading, spacing: 10) {
                EditorField(label: "Local socket bind mask", hint: "Octal") {
                    TextField("0177", text: $streamBindMask)
                        .font(.system(size: 11.5, design: .monospaced))
                        .accessibilityLabel("Local socket bind mask")
                }

                Toggle(
                    "Retry cleanup of RelayBar-owned stale local sockets",
                    isOn: $unlinkStaleSocket
                )
                .font(.system(size: 10.5))

                Text(
                    "RelayBar never replaces an existing file, directory, symlink, or unowned socket."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.system(size: 11.5, weight: .medium))
    }

    @ViewBuilder
    private var safetyMessages: some View {
        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
            if rule.exposesBeyondLoopback {
                Label(
                    "Rule \(index + 1) listens beyond loopback \(rule.kind.listensRemotely ? "on the SSH server" : "on this Mac") at \(rule.listenAddress).",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
            }
        }

        if hasLocalSOCKS {
            Label(
                "For remote hostname resolution, configure the client to send hostnames through SOCKS5 (often called socks5h).",
                systemImage: "network"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }

        if hasReverseSOCKS, reversePolicyChoice == .unspecified {
            Label(
                "Choose an explicit destination policy for Remote SOCKS.",
                systemImage: "exclamationmark.circle.fill"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(.red)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button(tunnel == nil ? "Add Profile" : "Save Changes", action: save)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isValid)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var builtTunnel: Tunnel? {
        let builtRules = rules.compactMap(\.forwardingRule)
        guard builtRules.count == rules.count, !builtRules.isEmpty else { return nil }
        guard let mask = UInt16(streamBindMask, radix: 8), mask <= 0o777 else {
            return nil
        }

        let reversePolicy: ReverseSOCKSPolicy?
        if builtRules.contains(where: { $0.kind == .remoteDynamic }) {
            switch reversePolicyChoice {
            case .unspecified:
                return nil
            case .any:
                reversePolicy = .any
            case .none:
                reversePolicy = ReverseSOCKSPolicy.none
            case .restricted:
                let destinations = reverseAllowedDestinations
                    .split(whereSeparator: { $0.isWhitespace || $0 == "," })
                    .map(String.init)
                guard
                    !destinations.isEmpty,
                    destinations.allSatisfy(
                        SSHArgumentPolicy.isValidPermitRemoteOpenDestination
                    )
                else {
                    return nil
                }
                reversePolicy = .allow(destinations)
            }
        } else {
            reversePolicy = nil
        }

        let profile = Tunnel(
            id: tunnel?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            sshHost: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
            additionalArguments: additionalArguments,
            rules: builtRules,
            reverseSOCKSPolicy: reversePolicy,
            streamLocalSettings: StreamLocalSettings(
                bindMask: mask,
                unlinkStaleSocket: unlinkStaleSocket
            ),
            groupTag: groupTag
        )
        return profile.isSafeToRun ? profile : nil
    }

    private var isValid: Bool {
        !hasPendingGroupName && builtTunnel != nil
    }

    private var hasReverseSOCKS: Bool {
        rules.contains { $0.kind == .remoteDynamic }
    }

    private var hasLocalSOCKS: Bool {
        rules.contains { $0.kind == .localDynamic }
    }

    private var usesUnixSockets: Bool {
        rules.contains { $0.listenKind == .unix || (!$0.kind.isDynamic && $0.destinationKind == .unix) }
    }

    private func importCommand() {
        do {
            let imported = try SSHCommandParser.parse(command)
            rules = imported.rules.map(ForwardingRuleDraft.init)
            sshHost = imported.sshHost
            additionalArguments = imported.additionalArguments
            streamBindMask = imported.streamLocalSettings.bindMaskArgument
            unlinkStaleSocket = imported.streamLocalSettings.unlinkStaleSocket

            switch imported.reverseSOCKSPolicy {
            case .some(.any):
                reversePolicyChoice = .any
                reverseAllowedDestinations = ""
            case .some(.none):
                reversePolicyChoice = .none
                reverseAllowedDestinations = ""
            case .some(.allow(let destinations)):
                reversePolicyChoice = .restricted
                reverseAllowedDestinations = destinations.joined(separator: "\n")
            case nil:
                reversePolicyChoice = .unspecified
                reverseAllowedDestinations = ""
            }

            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = imported.rules.count == 1
                    ? imported.rules[0].displaySummary
                    : "\(imported.sshHost) · \(imported.rules.count) rules"
            }
            importError = nil
            focusedField = .name
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func save() {
        guard let profile = builtTunnel else { return }
        onSave(profile)
    }

    private func rulePosition(_ id: UUID) -> Int {
        (rules.firstIndex(where: { $0.id == id }) ?? 0) + 1
    }

    private func moveRule(_ id: UUID, offset: Int) {
        guard let source = rules.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard rules.indices.contains(destination) else { return }
        rules.swapAt(source, destination)
    }

    private func duplicateRule(_ id: UUID) {
        guard
            let index = rules.firstIndex(where: { $0.id == id })
        else {
            return
        }
        var copy = rules[index]
        copy.id = UUID()
        rules.insert(copy, at: index + 1)
    }

    private func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

private struct GroupSelectionControl: View {
    @Binding var selection: String?
    @Binding var hasPendingName: Bool
    let availableGroups: [String]

    @State private var isNamingNewGroup = false
    @State private var draftName = ""
    @State private var validationMessage: String?
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        EditorField(label: "Group", hint: "Optional") {
            if isNamingNewGroup {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        TextField("New group name", text: $draftName)
                            .accessibilityLabel("New group name")
                            .focused($isDraftFocused)
                            .onSubmit(commitDraft)
                            .onExitCommand(perform: cancelDraft)

                        Button(action: commitDraft) {
                            Image(systemName: "checkmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Create group")
                        .accessibilityLabel("Create group")

                        Button(action: cancelDraft) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel new group")
                        .accessibilityLabel("Cancel new group")
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                .onAppear {
                    isDraftFocused = true
                }
            } else {
                Picker("Group", selection: pickerSelection) {
                    Text("Ungrouped").tag(GroupPickerChoice.ungrouped)
                    ForEach(groupChoices, id: \.self) { group in
                        Text(group).tag(GroupPickerChoice.named(group))
                    }
                    Divider()
                    Text("New Group…").tag(GroupPickerChoice.newGroup)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Group, Optional")
            }
        }
    }

    private var pickerSelection: Binding<GroupPickerChoice> {
        Binding {
            selection.map(GroupPickerChoice.named) ?? .ungrouped
        } set: { choice in
            switch choice {
            case .ungrouped:
                selection = nil
            case .named(let group):
                selection = group
            case .newGroup:
                draftName = ""
                validationMessage = nil
                isNamingNewGroup = true
                hasPendingName = true
            }
        }
    }

    private var groupChoices: [String] {
        var names = availableGroups
        if
            let selection,
            !names.contains(where: {
                TunnelGroupTag.canonicalKey($0)
                    == TunnelGroupTag.canonicalKey(selection)
            })
        {
            names.append(selection)
            names.sort {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        }
        return names
    }

    private func commitDraft() {
        switch TunnelGroupTag.resolve(
            draftName,
            existingNames: availableGroups
        ) {
        case .ungrouped:
            validationMessage = "Enter a group name."
        case .invalid(let message):
            validationMessage = message
        case .valid(let normalized):
            selection = normalized
            validationMessage = nil
            isNamingNewGroup = false
            hasPendingName = false
        }
    }

    private func cancelDraft() {
        draftName = ""
        validationMessage = nil
        isNamingNewGroup = false
        hasPendingName = false
    }
}

private enum GroupPickerChoice: Hashable {
    case ungrouped
    case named(String)
    case newGroup
}

private struct ForwardingRuleEditor: View {
    @Binding var draft: ForwardingRuleDraft
    let position: Int
    let count: Int
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rule \(position)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()

                Button(action: onMoveUp) {
                    Image(systemName: "arrow.up")
                }
                .disabled(position == 1)
                .help("Move rule up")
                .accessibilityLabel("Move rule \(position) up")

                Button(action: onMoveDown) {
                    Image(systemName: "arrow.down")
                }
                .disabled(position == count)
                .help("Move rule down")
                .accessibilityLabel("Move rule \(position) down")

                Button(action: onDuplicate) {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate rule")
                .accessibilityLabel("Duplicate rule \(position)")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete rule")
                .accessibilityLabel("Delete rule \(position)")
            }
            .buttonStyle(.borderless)

            Picker("Type", selection: $draft.kind) {
                ForEach(ForwardingRuleKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.kind) { newKind in
                if newKind.isDynamic {
                    draft.listenKind = .tcp
                }
            }

            endpointEditor(
                title: draft.kind.listensRemotely
                    ? "Listen on SSH server"
                    : "Listen on this Mac",
                kind: $draft.listenKind,
                address: $draft.listenAddress,
                port: $draft.listenPort,
                path: $draft.listenPath,
                allowsAutomaticPort: draft.kind.listensRemotely,
                kindLockedToTCP: draft.kind.isDynamic
            )

            if !draft.kind.isDynamic {
                endpointEditor(
                    title: draft.kind.listensRemotely
                        ? "Connect from this Mac to"
                        : "Connect from SSH server to",
                    kind: $draft.destinationKind,
                    address: $draft.destinationHost,
                    port: $draft.destinationPort,
                    path: $draft.destinationPath,
                    allowsAutomaticPort: false,
                    kindLockedToTCP: false
                )
            } else {
                Text(
                    draft.kind == .localDynamic
                        ? "SOCKS clients connect here; destinations open from the SSH server."
                        : "Remote SOCKS clients connect here; destinations open from this Mac."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    private func endpointEditor(
        title: String,
        kind: Binding<ForwardListenEndpoint.Kind>,
        address: Binding<String>,
        port: Binding<String>,
        path: Binding<String>,
        allowsAutomaticPort: Bool,
        kindLockedToTCP: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                Spacer()
                if !kindLockedToTCP {
                    Picker("Endpoint type", selection: kind) {
                        Text("TCP").tag(ForwardListenEndpoint.Kind.tcp)
                        Text("Unix").tag(ForwardListenEndpoint.Kind.unix)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 112)
                }
            }

            if kind.wrappedValue == .tcp {
                HStack(spacing: 8) {
                    TextField("localhost", text: address)
                        .accessibilityLabel("\(title) address")
                    TextField(allowsAutomaticPort ? "0 = Automatic" : "Port", text: port)
                        .frame(width: 108)
                        .accessibilityLabel("\(title) port")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
            } else {
                TextField("/absolute/socket/path", text: path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .accessibilityLabel("\(title) Unix socket path")
            }
        }
    }
}

private struct ForwardingRuleDraft: Identifiable {
    var id: UUID
    var kind: ForwardingRuleKind
    var listenKind: ForwardListenEndpoint.Kind
    var listenAddress: String
    var listenPort: String
    var listenPath: String
    var destinationKind: ForwardListenEndpoint.Kind
    var destinationHost: String
    var destinationPort: String
    var destinationPath: String

    init(kind: ForwardingRuleKind) {
        id = UUID()
        self.kind = kind
        listenKind = .tcp
        listenAddress = "localhost"
        listenPort = ""
        listenPath = ""
        destinationKind = .tcp
        destinationHost = "localhost"
        destinationPort = ""
        destinationPath = ""
    }

    init(_ rule: ForwardingRule) {
        id = rule.id
        kind = rule.kind
        listenKind = rule.listen.kind
        listenAddress = rule.listen.tcp?.bindAddress ?? ""
        listenPort = rule.listen.tcp.map { String($0.port) } ?? ""
        listenPath = rule.listen.path ?? ""
        destinationKind = rule.destination?.kind == .unix ? .unix : .tcp
        destinationHost = rule.destination?.tcp?.host ?? ""
        destinationPort = rule.destination?.tcp.map { String($0.port) } ?? ""
        destinationPath = rule.destination?.path ?? ""
    }

    var forwardingRule: ForwardingRule? {
        let listen: ForwardListenEndpoint
        switch listenKind {
        case .tcp:
            guard let port = Int(listenPort) else { return nil }
            let bind = listenAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            listen = .tcp(bindAddress: bind.isEmpty ? nil : bind, port: port)
        case .unix:
            listen = .unix(
                path: listenPath.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let destination: ForwardDestinationEndpoint?
        if kind.isDynamic {
            destination = nil
        } else {
            switch destinationKind {
            case .tcp:
                guard let port = Int(destinationPort) else { return nil }
                destination = .tcp(
                    host: destinationHost.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: port
                )
            case .unix:
                destination = .unix(
                    path: destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        let rule = ForwardingRule(
            id: id,
            kind: kind,
            listen: listen,
            destination: destination
        )
        return rule.isValid ? rule : nil
    }

    var exposesBeyondLoopback: Bool {
        guard listenKind == .tcp else { return false }
        return TCPListenEndpoint(
            bindAddress: listenAddress,
            port: Int(listenPort) ?? 1
        ).exposesBeyondLoopback
    }
}

private enum ReversePolicyChoice: String, CaseIterable {
    case unspecified
    case any
    case restricted
    case none

    var label: String {
        switch self {
        case .unspecified: "Choose…"
        case .any: "Any destination"
        case .restricted: "Allowlist"
        case .none: "No destinations"
        }
    }
}

private struct EditorField<Content: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                if let hint {
                    Text("· \(hint)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            content
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
        }
    }
}
