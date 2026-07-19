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
                    onEdit: { screen = .editor($0) }
                )
            case .editor(let tunnel):
                TunnelEditorView(
                    tunnel: tunnel,
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.tunnels.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(store.tunnels) { tunnel in
                            TunnelRow(
                                tunnel: tunnel,
                                phase: store.phase(for: tunnel),
                                onToggle: { store.toggle(tunnel) },
                                onOpen: { store.openInBrowser(tunnel) },
                                onEdit: { onEdit(tunnel) },
                                onDelete: { store.delete(tunnel) }
                            )
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            footer
        }
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
}

private struct TunnelRow: View {
    let tunnel: Tunnel
    let phase: TunnelPhase
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
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

                Text("\(tunnel.localEndpoint)  →  \(tunnel.destinationEndpoint)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(errorOrHost)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onOpen) {
                Image(systemName: "safari")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(openButtonHelp)
            .accessibilityLabel("Open \(tunnel.displayName) in browser")

            Menu {
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
            .help(isActive ? "Stop tunnel" : "Start tunnel")
            .accessibilityLabel(isActive ? "Stop \(tunnel.displayName)" : "Start \(tunnel.displayName)")
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
