import AppKit
import SwiftUI

/// In-popover settings screen. Shares the editor screen's navigation idiom so
/// list → settings feels like one surface.
struct SettingsView: View {
    @ObservedObject var store: TunnelStore
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    @ObservedObject var updates: UpdateModel
    @StateObject private var about: ApplicationAboutModel
    let onBack: () -> Void

    init(
        store: TunnelStore,
        launchAtLogin: LaunchAtLoginModel,
        updates: UpdateModel,
        about: ApplicationAboutModel = ApplicationAboutModel(),
        onBack: @escaping () -> Void
    ) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self.updates = updates
        _about = StateObject(wrappedValue: about)
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            PopoverScrollContainer(fillsViewport: true) {
                VStack(alignment: .leading, spacing: 18) {
                    generalSection
                    Spacer(minLength: 8)
                    aboutFooter
                }
            }
        }
        .onExitCommand(perform: onBack)
        .onAppear {
            launchAtLogin.refresh()
            updates.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            launchAtLogin.refresh()
            updates.refresh()
        }
        .onDisappear {
            about.cancelTransientState()
            updates.cancelTransientState()
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
                Divider()
                    .padding(.horizontal, 12)
                automaticUpdatesRow
                Divider()
                    .padding(.horizontal, 12)
                retryLimitRow
            }
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )

            Text("Retries wait 5s, 10s, 20s… up to 5 minutes. The retry count resets after 1 minute connected.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var retryLimitRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("SSH Retry Limit")
                    .font(.system(size: 12.5, weight: .medium))
                Text("For all profiles. 0 turns off retries.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text("\(store.maxRetryAttempts)")
                .font(.system(size: 12.5).monospacedDigit())
                .frame(minWidth: 25, alignment: .trailing)
                .accessibilityHidden(true)
            Stepper(
                "SSH Retry Limit",
                value: Binding(
                    get: { store.maxRetryAttempts },
                    set: { store.setMaxRetryAttempts($0) }
                ),
                in: TunnelStore.retryLimitRange
            )
            .labelsHidden()
            .fixedSize()
            .accessibilityValue(
                store.maxRetryAttempts == 0 ? "Off" : "\(store.maxRetryAttempts) retries"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private var automaticUpdatesRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic Updates")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Checks about once a week and offers new versions. Nothing installs without you.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle(
                "Automatic Updates",
                isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { updates.setAutomaticallyChecksForUpdates($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!updates.isAvailable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
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
                Text("Open at login; profiles stay stopped.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var aboutFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(about.metadata.displayText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(about.metadata.accessibilityLabel)

                Button(action: about.copyVersion) {
                    Image(systemName: about.didCopyVersion ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentTransition(.identity)
                }
                .buttonStyle(.plain)
                .help("Copy version and build")
                .accessibilityLabel("Copy version and build")

                Spacer()
            }

            HStack(spacing: 7) {
                footerLink(
                    "Check for Updates…",
                    isEnabled: updates.canCheckForUpdates,
                    action: updates.checkForUpdates
                )
                    .accessibilityHint("Checks the RelayBar update feed")

                updateStatus
            }

            HStack(spacing: 5) {
                footerLink("Website", action: about.openWebsite)
                    .accessibilityLabel("Open RelayBar website in browser")
                Text("·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                footerLink("GitHub", action: about.openRepository)
                    .accessibilityLabel("Open RelayBar on GitHub in browser")
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var updateStatus: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking…")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Checking for updates")
        case .upToDate:
            Text("You're up to date.")
                .accessibilityLabel("RelayBar is up to date")
        case .failed:
            Text("Couldn't check. Try again.")
                .accessibilityLabel("Couldn't check for updates. Try again.")
        case .waitingForTunnels(let count):
            let noun = count == 1 ? "tunnel" : "tunnels"
            Text("Update ready. Stop \(count) \(noun) to finish.")
                .accessibilityLabel(
                    "Update ready. Stop \(count) \(noun) to finish installing."
                )
        }
    }

    private func footerLink(
        _ title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(size: 10.5))
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .buttonStyle(.plain)
            .disabled(!isEnabled)
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
