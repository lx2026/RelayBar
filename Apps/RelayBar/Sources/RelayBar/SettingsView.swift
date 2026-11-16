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
    let composition: RelayBarComposition?
    let onRevokeFrame: () -> Void

    init(
        store: TunnelStore,
        launchAtLogin: LaunchAtLoginModel,
        updates: UpdateModel,
        about: ApplicationAboutModel = ApplicationAboutModel(),
        composition: RelayBarComposition? = nil,
        onRevokeFrame: @escaping () -> Void = {},
        onBack: @escaping () -> Void
    ) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self.updates = updates
        _about = StateObject(wrappedValue: about)
        self.onBack = onBack
        self.composition = composition; self.onRevokeFrame = onRevokeFrame
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            PopoverScrollContainer(fillsViewport: true) {
                VStack(alignment: .leading, spacing: 16) {
                    generalSection
                    if let composition {
                        FrameAccessRow(composition: composition, onRevoke: onRevokeFrame)
                        RelayPreviewSettings(composition: composition)
                    }
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
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(PopoverIconButtonStyle())
            .accessibilityLabel("Back")

            Text("Settings")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, RelayBarPopoverLayout.contentInset)
        .frame(minHeight: RelayBarPopoverLayout.headerHeight)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("GENERAL")

            VStack(spacing: 0) {
                launchAtLoginRow
                if hasLaunchAtLoginCaption {
                    Divider()
                        .padding(.horizontal, 12)
                    launchAtLoginCaption
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                    .padding(.horizontal, 12)
                automaticUpdatesRow
                Divider()
                    .padding(.horizontal, 12)
                retryLimitRow
                if let composition {
                    Divider()
                        .padding(.horizontal, 12)
                    pluginsRow(composition)
                }
            }
            .popoverCard()

            Text("Retries wait 5s, 10s, 20s… up to 5 minutes. The retry count resets after 1 minute connected.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One General row: symbol, title, a line of detail, and its control.
    private func settingRow<Control: View>(
        _ systemImage: String,
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            control()
        }
        .padding(12)
    }

    private var retryLimitRow: some View {
        settingRow(
            "arrow.clockwise",
            title: "SSH Retry Limit",
            detail: "For all profiles. 0 turns off retries."
        ) {
            Text("\(store.maxRetryAttempts)")
                .font(.body.monospacedDigit())
                .frame(minWidth: 24, alignment: .trailing)
                .accessibilityHidden(true)
            Stepper(
                "SSH Retry Limit",
                value: Binding(
                    get: { store.maxRetryAttempts },
                    set: { value in
                        if let composition {
                            Task {
                                do { try await composition.setRetryLimit(value) }
                                catch { composition.errorMessage = error.localizedDescription }
                            }
                        } else { store.setMaxRetryAttempts(value) }
                    }
                ),
                in: TunnelStore.retryLimitRange
            )
            .labelsHidden()
            .fixedSize()
            .accessibilityValue(
                store.maxRetryAttempts == 0 ? "Off" : "\(store.maxRetryAttempts) retries"
            )
        }
    }

    private func pluginsRow(_ composition: RelayBarComposition) -> some View {
        settingRow(
            "puzzlepiece.extension",
            title: "Plugins",
            detail: "Optional features and what they depend on"
        ) {
            Button("Open…", action: composition.showPlugins)
                .controlSize(.small)
                .accessibilityLabel("Open Plugins")
        }
    }

    private var automaticUpdatesRow: some View {
        settingRow(
            "arrow.triangle.2.circlepath",
            title: "Automatic Updates",
            detail: "Checks about once a week and offers new versions. Nothing installs without you."
        ) {
            Toggle(
                "Automatic Updates",
                isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { value in
                        if let composition {
                            Task {
                                do { try await composition.setAutomaticUpdates(value) }
                                catch { composition.errorMessage = error.localizedDescription }
                            }
                        } else { updates.setAutomaticallyChecksForUpdates(value) }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!updates.isAvailable)
        }
    }

    private var launchAtLoginRow: some View {
        settingRow(
            "power",
            title: "Launch at Login",
            detail: "Open at login; profiles stay stopped."
        ) {
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
    }

    private var aboutFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(about.metadata.displayText)
                    .accessibilityLabel(about.metadata.accessibilityLabel)

                Button(action: about.copyVersion) {
                    Image(systemName: about.didCopyVersion ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .contentTransition(.identity)
                }
                .buttonStyle(.plain)
                .help("Copy version and build")
                .accessibilityLabel("Copy version and build")

                Spacer()
            }

            HStack(spacing: 8) {
                footerLink(
                    "Check for Updates…",
                    isEnabled: updates.canCheckForUpdates,
                    action: updates.checkForUpdates
                )
                    .accessibilityHint("Checks the RelayBar update feed")

                updateStatus
            }

            HStack(spacing: 4) {
                footerLink("Website", action: about.openWebsite)
                    .accessibilityLabel("Open RelayBar website in browser")
                Text("·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                footerLink("GitHub", action: about.openRepository)
                    .accessibilityLabel("Open RelayBar on GitHub in browser")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Needs approval — open Login Items settings")
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Login Items settings to approve launching at login")
        case .notFound:
            Text("macOS couldn’t find this copy of RelayBar as a login item.")
                .foregroundStyle(.secondary)
        case .error(status: _, message: let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
        }
    }
}

/// Frame's access grant, shown only while Open in Frame runs and Frame has been allowed in.
private struct FrameAccessRow: View {
    @ObservedObject var composition: RelayBarComposition
    @AppStorage("frameViewer.readAccess.v1") private var frameAllowed = false
    let onRevoke: () -> Void

    var body: some View {
        if frameAllowed, composition.frameHost != nil {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Frame Viewer").font(.body.weight(.medium))
                    Text("Remote folder access").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revoke", role: .destructive) { onRevoke(); frameAllowed = false }
                    .foregroundStyle(.red)
            }
            .padding(12)
            .popoverCard()
        }
    }
}

private struct RelayPreviewSettings: View {
    @ObservedObject var composition: RelayBarComposition
    private let mib: Int64 = 1_024 * 1_024
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("PREVIEWS")
            VStack(spacing: 0) {
                ForEach(Array(RemotePreviewPlugins.descriptors.enumerated()), id: \.element.id) { index, descriptor in
                    if index > 0 { Divider().padding(.horizontal, 12) }
                    HStack(spacing: 8) {
                        Toggle(descriptor.title, isOn: Binding(get: { composition.previewEnabled(descriptor.id) }, set: { value in
                            Task {
                                do { try await composition.setPreviewEnabled(descriptor.id, value) }
                                catch { composition.errorMessage = error.localizedDescription }
                            }
                        }))
                        Spacer(minLength: 8)
                        Picker("Size limit", selection: Binding(get: { composition.previewLimit(descriptor.id) }, set: { bytes in
                            Task {
                                do { try await composition.setPreviewLimit(descriptor.id, bytes) }
                                catch { composition.errorMessage = error.localizedDescription }
                            }
                        })) {
                            let sizes = Set([1, 2, 5, 10, 25, 50, 100, 200, 500].map { Int64($0) * mib }
                                .filter { $0 <= descriptor.maximumBytes } + [descriptor.maximumBytes]).sorted()
                            ForEach(sizes, id: \.self) { bytes in Text("\(bytes / mib) MiB").tag(bytes) }
                        }.fixedSize().disabled(!composition.previewEnabled(descriptor.id))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .popoverCard()
        }
    }
}
