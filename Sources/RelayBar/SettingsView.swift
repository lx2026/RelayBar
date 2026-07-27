import AppKit
import SwiftUI

/// In-popover settings screen. Shares the editor screen's navigation idiom so
/// list → settings feels like one surface.
struct SettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    generalSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onExitCommand(perform: onBack)
        .onAppear(perform: launchAtLogin.refresh)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            launchAtLogin.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("GENERAL")

            VStack(spacing: 0) {
                launchAtLoginRow
                if hasLaunchAtLoginCaption {
                    Divider()
                        .padding(.horizontal, 12)
                    launchAtLoginCaption
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )

            Text("A login launch opens the menu bar item only — saved profiles stay stopped until you start them.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var launchAtLoginRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at Login")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Open RelayBar when you log in")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Bound to the authoritative system status, including when the
            // latest register or unregister operation surfaced an error.
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLogin.state.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var hasLaunchAtLoginCaption: Bool {
        switch launchAtLogin.state {
        case .notRegistered, .enabled: false
        case .requiresApproval, .notFound, .error: true
        }
    }

    @ViewBuilder private var launchAtLoginCaption: some View {
        switch launchAtLogin.state {
        case .notRegistered, .enabled:
            EmptyView()
        case .requiresApproval:
            Button(action: launchAtLogin.openLoginItemsSettings) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("Needs approval — open Login Items settings")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Login Items settings to approve launching at login")
        case .notFound:
            Text("macOS couldn’t find this copy of RelayBar as a login item.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .error(status: _, message: let message):
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}
