import AppKit
import HouseStyle
import PreviewSupport
import SwiftUI

enum SettingsLayout {
    static let width: CGFloat = 480
    static let rowInset: CGFloat = 14
    static let boxCornerRadius: CGFloat = 10
    static let sizeLimitWidth: CGFloat = 96
}

/// The Settings window's content: General, Previews, Frame access and About.
/// Its height is always its fitting height, so it never scrolls.
struct SettingsView: View {
    @HouseTracking private var house
    @ObservedObject var store: TunnelStore
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    @ObservedObject var updates: UpdateModel
    @ObservedObject var about: ApplicationAboutModel
    @ObservedObject var composition: RelayBarComposition
    @State private var retryDraft: Int?
    @FocusState private var retryFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsBox {
                launchAtLoginRow
                SettingsDivider()
                automaticUpdatesRow
                SettingsDivider()
                retryLimitRow
                SettingsDivider()
                pluginsRow
            }

            Text("Retries wait 5s, 10s, 20s… up to 5 minutes. The retry count resets after 1 minute connected.")
                .font(.system(size: 11))
                .foregroundStyle(HouseColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsLayout.rowInset)
                .padding(.top, 8)

            RelayPreviewSettings(composition: composition)
                .padding(.top, 20)

            FrameAccessBox(composition: composition)
                .defaultAppStorage(composition.environment.defaults)

            aboutBox
                .padding(.top, 20)

            footer
                .padding(.horizontal, SettingsLayout.rowInset)
                .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20))
        .frame(width: SettingsLayout.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(HouseColor.ink)
        .background(HouseColor.panel)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            launchAtLogin.refresh()
            updates.refresh()
        }
    }

    // MARK: General

    private var launchAtLoginRow: some View {
        SettingsRow(
            title: "Launch at Login",
            detail: "Open at login; profiles stay stopped."
        ) {
            launchAtLoginNote
        } control: {
            // Bound to the authoritative system status, including when the
            // latest register or unregister operation surfaced an error.
            settingsSwitch(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLogin.state.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
        }
    }

    @ViewBuilder private var launchAtLoginNote: some View {
        switch launchAtLogin.state {
        case .notRegistered, .enabled:
            EmptyView()
        case .requiresApproval:
            Button(action: launchAtLogin.openLoginItemsSettings) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(HouseColor.warning)
                    Text("Needs approval — open Login Items settings")
                        .foregroundStyle(Color(nsColor: .linkColor))
                }
                .font(.system(size: 11))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel("Open Login Items settings to approve launching at login")
        case .notFound:
            Text("macOS couldn’t find this copy of RelayBar as a login item.")
                .font(.system(size: 11))
                .foregroundStyle(HouseColor.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .error(status: _, message: let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(HouseColor.failure)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(message)
                .padding(.top, 2)
        }
    }

    private var automaticUpdatesRow: some View {
        SettingsRow(
            title: "Automatic Updates",
            detail: "Checks about once a week and offers new versions. Nothing installs without you."
        ) {
            settingsSwitch(
                "Automatic Updates",
                isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: { value in
                        Task {
                            do { try await composition.setAutomaticUpdates(value) }
                            catch { composition.errorMessage = error.localizedDescription }
                        }
                    }
                )
            )
            .disabled(!updates.isAvailable)
        }
    }

    private var retryLimitRow: some View {
        SettingsRow(
            title: "SSH Retry Limit",
            detail: "For all profiles. 0 turns off retries."
        ) {
            HStack(spacing: 4) {
                // The field writes its value on every keystroke, so typing
                // goes to a draft; only the finished number reaches the
                // running tunnels, never the "1" on the way to "10".
                TextField(
                    "SSH Retry Limit",
                    value: Binding(
                        get: { retryDraft ?? store.maxRetryAttempts },
                        set: { retryDraft = $0 }
                    ),
                    format: .number
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13).monospacedDigit())
                .frame(width: 40)
                .focused($retryFieldFocused)
                .onSubmit(commitRetryDraft)
                .onChange(of: retryFieldFocused) { focused in
                    if !focused { commitRetryDraft() }
                }
                .onChange(of: store.maxRetryAttempts) { value in
                    if retryDraft == value || !retryFieldFocused { retryDraft = nil }
                }
                .accessibilityValue(retryAccessibilityValue)

                Stepper(
                    "SSH Retry Limit",
                    value: Binding(
                        get: { store.maxRetryAttempts },
                        set: { setRetryLimit($0) }
                    ),
                    in: TunnelStore.retryLimitRange
                )
                .labelsHidden()
                .fixedSize()
                .accessibilityValue(retryAccessibilityValue)
            }
        }
    }

    private func commitRetryDraft() {
        guard let draft = retryDraft else { return }
        setRetryLimit(draft)
    }

    /// Typed values outside 0–100 are clamped rather than refused.
    private func setRetryLimit(_ value: Int) {
        let range = TunnelStore.retryLimitRange
        let limit = min(max(value, range.lowerBound), range.upperBound)
        guard limit != store.maxRetryAttempts else {
            retryDraft = nil
            return
        }
        // Shows the clamped value until the store reports it.
        retryDraft = limit
        Task {
            do { try await composition.setRetryLimit(limit) }
            catch {
                retryDraft = nil
                composition.errorMessage = error.localizedDescription
            }
        }
    }

    private var retryAccessibilityValue: String {
        store.maxRetryAttempts == 0 ? "Off" : "\(store.maxRetryAttempts) retries"
    }

    private var pluginsRow: some View {
        SettingsRow(
            title: "Plugins",
            detail: "Optional features and what they depend on"
        ) {
            Button("Open…", action: composition.showPlugins)
                .accessibilityLabel("Open Plugins")
        }
    }

    // MARK: About

    private var aboutBox: some View {
        SettingsBox {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(about.metadata.name)
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(about.metadata.versionLine)
                            .accessibilityLabel(about.metadata.accessibilityLabel)
                        Button(action: about.copyVersion) {
                            Image(systemName: about.didCopyVersion ? "checkmark" : "doc.on.doc")
                                .frame(width: 14, height: 14)
                                .contentTransition(.identity)
                        }
                        .buttonStyle(.plain)
                        .help("Copy version and build")
                        .accessibilityLabel("Copy version and build")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(HouseColor.muted)
                    updateStatus
                        .font(.system(size: 11))
                        .foregroundStyle(HouseColor.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                    .accessibilityHint("Checks the RelayBar update feed")
            }
            .padding(.horizontal, SettingsLayout.rowInset)
            .padding(.vertical, 12)
        }
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
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    "Update ready. Stop \(count) \(noun) to finish installing."
                )
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .accessibilityHidden(true)
            Text("Uses macOS SSH")
            Spacer(minLength: 12)
            footerLink("Website", action: about.openWebsite)
                .accessibilityLabel("Open RelayBar website in browser")
            Text("·")
                .accessibilityHidden(true)
            footerLink("GitHub", action: about.openRepository)
                .accessibilityLabel("Open RelayBar on GitHub in browser")
        }
        .font(.system(size: 11))
        .foregroundStyle(HouseColor.muted)
    }

    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .linkColor))
    }
}

/// A switch at the size every Settings toggle uses.
@MainActor
private func settingsSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
}

/// A rounded panel with a hairline edge that holds Settings rows.
private struct SettingsBox<Content: View>: View {
    @HouseTracking private var house
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: SettingsLayout.boxCornerRadius,
            style: .continuous
        )
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(HouseColor.card))
        // Outside the edge, so the hairline is one crisp pixel on Retina.
        .overlay(shape.inset(by: -0.25).stroke(HouseColor.line, lineWidth: 0.5))
    }
}

private struct SettingsDivider: View {
    var body: some View {
        HouseDivider()
            .padding(.horizontal, SettingsLayout.rowInset)
    }
}

/// A title, a line of detail, an optional note under it, and a trailing control.
private struct SettingsRow<Note: View, Control: View>: View {
    @HouseTracking private var house
    let title: String
    let detail: String
    @ViewBuilder let note: Note
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(HouseColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                note
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
        }
        .padding(.horizontal, SettingsLayout.rowInset)
        .padding(.vertical, 10)
    }
}

extension SettingsRow where Note == EmptyView {
    init(title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.init(title: title, detail: detail, note: { EmptyView() }, control: control)
    }
}

/// Frame's access grant, shown only while Open in Frame runs and Frame has been allowed in.
private struct FrameAccessBox: View {
    @ObservedObject var composition: RelayBarComposition
    @AppStorage("frameViewer.readAccess.v1") private var frameAllowed = false

    var body: some View {
        if frameAllowed, composition.frameHost != nil {
            SettingsBox {
                SettingsRow(title: "Frame Viewer", detail: "Remote folder access") {
                    Button("Revoke", role: .destructive) {
                        composition.revokeFrame()
                        frameAllowed = false
                    }
                    .foregroundStyle(.red)
                }
            }
            .padding(.top, 20)
        }
    }
}

private struct RelayPreviewSettings: View {
    @HouseTracking private var house
    @ObservedObject var composition: RelayBarComposition
    private let mib: Int64 = 1_024 * 1_024

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Previews")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HouseColor.muted)
                .padding(.horizontal, SettingsLayout.rowInset)
                .accessibilityAddTraits(.isHeader)

            SettingsBox {
                ForEach(Array(RemotePreviewPlugins.descriptors.enumerated()), id: \.element.id) { index, descriptor in
                    if index > 0 { SettingsDivider() }
                    row(descriptor)
                }
            }
        }
        // One heading for the pop-up column, placed where the pop-ups are
        // whatever width the system gives the switches beside them.
        // Read here rather than in the closures, so a change of form redraws the heading with the body.
        .overlayPreferenceValue(SizeLimitColumn.self) { [muted = HouseColor.muted] anchor in
            if let anchor {
                GeometryReader { proxy in
                    Text("Size limit")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                        .offset(x: proxy[anchor].x)
                }
                // Each pop-up names its format and limit instead.
                .accessibilityHidden(true)
            }
        }
    }

    private func row(_ descriptor: PreviewDescriptor) -> some View {
        let enabled = composition.previewEnabled(descriptor.id)
        return HStack(spacing: 12) {
            // The switch carries the format's name for accessibility.
            Text(descriptor.title)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? HouseColor.ink : HouseColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)

            Picker("\(descriptor.title) size limit", selection: Binding(get: { composition.previewLimit(descriptor.id) }, set: { bytes in
                Task {
                    do { try await composition.setPreviewLimit(descriptor.id, bytes) }
                    catch { composition.errorMessage = error.localizedDescription }
                }
            })) {
                let sizes = Set([1, 2, 5, 10, 25, 50, 100, 200, 500].map { Int64($0) * mib }
                    .filter { $0 <= descriptor.maximumBytes } + [descriptor.maximumBytes]).sorted()
                ForEach(sizes, id: \.self) { bytes in Text("\(bytes / mib) MiB").tag(bytes) }
            }
            .labelsHidden()
            .fillsProposedWidth()
            .frame(width: SettingsLayout.sizeLimitWidth)
            .anchorPreference(key: SizeLimitColumn.self, value: .leading) { $0 }
            .disabled(!enabled)

            settingsSwitch(descriptor.title, isOn: Binding(get: { enabled }, set: { value in
                Task {
                    do { try await composition.setPreviewEnabled(descriptor.id, value) }
                    catch { composition.errorMessage = error.localizedDescription }
                }
            }))
        }
        .padding(.horizontal, SettingsLayout.rowInset)
        .frame(height: 36)
    }
}

/// The leading edge of the first preview pop-up.
private struct SizeLimitColumn: PreferenceKey {
    static var defaultValue: Anchor<CGPoint>? { nil }

    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

private extension View {
    /// From macOS 26 a pop-up hugs its title unless asked to fill its frame;
    /// earlier versions always fill it.
    @ViewBuilder func fillsProposedWidth() -> some View {
        if #available(macOS 26.0, *) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }
}

// MARK: - Window

/// The Settings window. It is made the first time Settings opens and closed when the app stops.
@MainActor
final class RelaySettingsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let about: ApplicationAboutModel
    private let composition: RelayBarComposition

    /// `windowType` lets a test put the content in a window that never appears.
    init(composition: RelayBarComposition, about: ApplicationAboutModel = ApplicationAboutModel(),
         windowType: SettingsWindow.Type = SettingsWindow.self) {
        self.composition = composition
        self.about = about
        // The hosting view's minimum and maximum size are both the content's
        // fitting size, so AppKit keeps the window exactly that size as rows
        // appear and disappear.
        let hosting = NSHostingView(rootView: SettingsWindowContent(composition: composition, about: about))
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        window = windowType.init(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "RelayBar Settings"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Otherwise AppKit focuses the first key view, the retry field, and
        // selects its number whenever the window opens.
        window.initialFirstResponder = hosting
        super.init()
        window.delegate = self
        window.center()
    }

    /// Opens the window, or brings the open one forward, and makes RelayBar active.
    func show() {
        composition.login?.refresh()
        composition.updates.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    /// Closing Settings clears its inline claims: a copy confirmation and an update result.
    func windowWillClose(_ notification: Notification) {
        endEditing()
        about.cancelTransientState()
        composition.updates.cancelTransientState()
    }

    func windowDidResignKey(_ notification: Notification) {
        endEditing()
    }

    /// A number typed into the retry field is saved when the field loses focus, and
    /// neither closing the window nor switching away takes focus from it.
    private func endEditing() {
        window.makeFirstResponder(nil)
    }
}

private struct SettingsWindowContent: View {
    @HouseTracking private var house
    @ObservedObject var composition: RelayBarComposition
    let about: ApplicationAboutModel

    var body: some View {
        Group {
            if let store = composition.store, let login = composition.login {
                SettingsView(
                    store: store,
                    launchAtLogin: login,
                    updates: composition.updates,
                    about: about,
                    composition: composition
                )
            } else {
                Text(composition.errorMessage ?? "Starting RelayBar…")
                    .foregroundStyle(HouseColor.muted)
                    .padding(20)
                    .frame(width: SettingsLayout.width)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("RelayBar", isPresented: Binding(get: { composition.errorMessage != nil }, set: {
            if !$0 { composition.errorMessage = nil }
        })) { Button("OK") { composition.errorMessage = nil } } message: { Text(composition.errorMessage ?? "") }
    }
}

/// Closes on Command-W and Escape. RelayBar has no main menu to supply them.
class SettingsWindow: NSWindow {
    required override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let closes = (modifiers == .command && event.charactersIgnoringModifiers == "w")
            || (modifiers.isEmpty && event.keyCode == 53)
        guard closes else { return false }
        performClose(nil)
        return true
    }
}
