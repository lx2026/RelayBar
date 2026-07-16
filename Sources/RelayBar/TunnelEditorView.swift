import SwiftUI

struct TunnelEditorView: View {
    let tunnel: Tunnel?
    let onCancel: () -> Void
    let onSave: (Tunnel) -> Void

    @State private var name: String
    @State private var sshHost: String
    @State private var localPort: String
    @State private var destinationHost: String
    @State private var destinationPort: String
    @State private var command = ""
    @State private var bindAddress: String?
    @State private var additionalArguments: [String]
    @State private var importError: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case command, name, sshHost, localPort, destinationHost, destinationPort
    }

    init(tunnel: Tunnel?, onCancel: @escaping () -> Void, onSave: @escaping (Tunnel) -> Void) {
        self.tunnel = tunnel
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: tunnel?.name ?? "")
        _sshHost = State(initialValue: tunnel?.sshHost ?? "")
        _localPort = State(initialValue: tunnel.map { String($0.localPort) } ?? "")
        _destinationHost = State(initialValue: tunnel?.destinationHost ?? "localhost")
        _destinationPort = State(initialValue: tunnel.map { String($0.destinationPort) } ?? "")
        _bindAddress = State(initialValue: tunnel?.bindAddress)
        _additionalArguments = State(initialValue: tunnel?.additionalArguments ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tunnel == nil { quickImport }
                    details
                }
                .padding(16)
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

            Text(tunnel == nil ? "New Tunnel" : "Edit Tunnel")
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
                TextField("ssh -N -L 8080:localhost:3000 user@host", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .focused($focusedField, equals: .command)
                    .onSubmit(importCommand)

                Button("Import", action: importCommand)
                    .buttonStyle(.bordered)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            } else {
                Text("Paste the command you already use. RelayBar fills in the rest.")
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

    private var details: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionLabel("DETAILS")

            EditorField(label: "Name", hint: "Optional") {
                TextField("Production database", text: $name)
                    .focused($focusedField, equals: .name)
            }

            EditorField(label: "SSH host", hint: "user@server") {
                TextField("user@bastion.example.com", text: $sshHost)
                    .focused($focusedField, equals: .sshHost)
            }

            HStack(spacing: 10) {
                EditorField(label: "Local port", hint: nil) {
                    TextField("5432", text: $localPort)
                        .focused($focusedField, equals: .localPort)
                }
                EditorField(label: "Destination", hint: nil) {
                    TextField("localhost", text: $destinationHost)
                        .focused($focusedField, equals: .destinationHost)
                }
                .frame(maxWidth: .infinity)
                EditorField(label: "Port", hint: nil) {
                    TextField("5432", text: $destinationPort)
                        .focused($focusedField, equals: .destinationPort)
                }
            }

            if exposesBeyondLoopback {
                Label("This tunnel listens beyond localhost.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
            } else if !additionalArguments.isEmpty || bindAddress != nil {
                Label("Imported SSH options will be preserved.", systemImage: "checkmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button(tunnel == nil ? "Add Tunnel" : "Save Changes", action: save)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isValid)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var isValid: Bool {
        guard
            SSHArgumentPolicy.isValidHostTarget(sshHost),
            SSHArgumentPolicy.isValidDestinationHost(destinationHost),
            SSHArgumentPolicy.areAdditionalArgumentsSafe(additionalArguments),
            let local = Int(localPort), (1...65_535).contains(local),
            let destination = Int(destinationPort), (1...65_535).contains(destination)
        else { return false }
        return true
    }

    private var exposesBeyondLoopback: Bool {
        guard let bindAddress else { return false }
        return Tunnel(
            name: name,
            localPort: Int(localPort) ?? 1,
            destinationHost: destinationHost,
            destinationPort: Int(destinationPort) ?? 1,
            sshHost: sshHost,
            bindAddress: bindAddress,
            additionalArguments: additionalArguments
        ).exposesBeyondLoopback
    }

    private func importCommand() {
        do {
            let imported = try SSHCommandParser.parse(command)
            localPort = String(imported.localPort)
            destinationHost = imported.destinationHost
            destinationPort = String(imported.destinationPort)
            sshHost = imported.sshHost
            bindAddress = imported.bindAddress
            additionalArguments = imported.additionalArguments
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = "\(imported.destinationHost):\(imported.destinationPort)"
            }
            importError = nil
            focusedField = .name
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        guard let local = Int(localPort), let destination = Int(destinationPort), isValid else { return }
        onSave(
            Tunnel(
                id: tunnel?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                localPort: local,
                destinationHost: destinationHost.trimmingCharacters(in: .whitespacesAndNewlines),
                destinationPort: destination,
                sshHost: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
                bindAddress: bindAddress,
                additionalArguments: additionalArguments
            )
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
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
