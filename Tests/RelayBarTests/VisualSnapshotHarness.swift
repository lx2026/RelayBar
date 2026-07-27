// Renders the menu window offscreen so a change to the saved list can be
// reviewed in both appearances without a screen-capture permission. Skipped
// unless RELAYBAR_SNAPSHOT_DIR is set, following the opt-in pattern the live
// SSH tests use.
import AppKit
import SwiftUI
import XCTest
@testable import RelayBar

@MainActor
final class VisualSnapshotHarness: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["RELAYBAR_SNAPSHOT_DIR"] ?? "")
    }

    func testCaptureTunnelListSnapshots() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RELAYBAR_SNAPSHOT_DIR"] == nil,
            "Set RELAYBAR_SNAPSHOT_DIR to capture snapshots."
        )

        let suiteName = "RelayBarSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TunnelStore(defaults: defaults)

        let fixtures: [(name: String, group: String?)] = [
            ("Hermes Dashboard", "Work"),
            ("Virtual Desktop", "Work"),
            ("Photos", "Personal"),
            ("Scratch", nil)
        ]
        for (index, fixture) in fixtures.enumerated() {
            store.add(
                Tunnel(
                    name: fixture.name,
                    localPort: 8_000 + index,
                    destinationHost: "localhost",
                    destinationPort: 3_000 + index,
                    sshHost: "preview-\(index + 1).example.com",
                    groupTag: fixture.group
                )
            )
        }

        // A local Unix-socket rule exercises the Task 014 Reveal path.
        store.add(
            Tunnel(
                name: "Socket Forward",
                sshHost: "gateway.example.com",
                rules: [
                    ForwardingRule(
                        kind: .local,
                        listen: .unix(path: "/tmp/relaybar-visual.sock"),
                        destination: .tcp(host: "localhost", port: 5_432)
                    )
                ],
                groupTag: "Work"
            )
        )

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let label = appearanceName == .aqua ? "light" : "dark"
            try capture(
                view: RelayBarRootView(
                    loginItemService: LoginItemServiceSpy(status: .enabled)
                )
                .environmentObject(store),
                appearance: appearanceName,
                to: outputDirectory.appendingPathComponent("tunnel-list-\(label).png")
            )
            try capture(
                view: SettingsView(
                    launchAtLogin: LaunchAtLoginModel(
                        service: LoginItemServiceSpy(status: .enabled)
                    ),
                    onBack: {}
                )
                .background(Color(nsColor: .windowBackgroundColor)),
                appearance: appearanceName,
                to: outputDirectory.appendingPathComponent("settings-\(label).png")
            )
            // The approval-required caption is the tallest Launch at Login
            // variant; capture it to verify the card's second row.
            try capture(
                view: SettingsView(
                    launchAtLogin: LaunchAtLoginModel(
                        service: LoginItemServiceSpy(status: .requiresApproval)
                    ),
                    onBack: {}
                )
                .background(Color(nsColor: .windowBackgroundColor)),
                appearance: appearanceName,
                to: outputDirectory.appendingPathComponent(
                    "settings-login-approval-\(label).png"
                )
            )
        }
    }

    func testCaptureTask021Snapshots() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RELAYBAR_SNAPSHOT_DIR"] == nil,
            "Set RELAYBAR_SNAPSHOT_DIR to capture snapshots."
        )

        let catalog = RemoteServerCatalog()
        _ = try catalog.add(name: "Development server", sshHost: "devbox.local")
        let remoteFilesModel = RemoteFilesModel(
            tunnels: [],
            serverCatalog: catalog
        )

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let label = appearanceName == .aqua ? "light" : "dark"
            try capture(
                view: TunnelEditorView(
                    tunnel: nil,
                    availableGroups: ["Personal", "Work"],
                    onCancel: {},
                    onSave: { _ in }
                )
                .background(Color(nsColor: .windowBackgroundColor)),
                appearance: appearanceName,
                size: NSSize(width: 380, height: 440),
                to: outputDirectory.appendingPathComponent(
                    "task-021-new-profile-\(label).png"
                )
            )
            try capture(
                view: RemoteFilesView(model: remoteFilesModel),
                appearance: appearanceName,
                size: NSSize(width: 360, height: 300),
                to: outputDirectory.appendingPathComponent(
                    "task-021-remote-files-\(label).png"
                )
            )
        }
    }

    func testCaptureTask025Snapshots() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["RELAYBAR_SNAPSHOT_DIR"] == nil,
            "Set RELAYBAR_SNAPSHOT_DIR to capture snapshots."
        )

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let label = appearanceName == .aqua ? "light" : "dark"
            try capture(
                view: TunnelEditorView(
                    tunnel: nil,
                    availableGroups: ["Personal", "Work"],
                    onCancel: {},
                    onSave: { _ in }
                )
                .background(Color(nsColor: .windowBackgroundColor)),
                appearance: appearanceName,
                size: NSSize(width: 380, height: 440),
                scrollOffsetY: 300,
                to: outputDirectory.appendingPathComponent(
                    "task-025-rule-type-\(label).png"
                )
            )
        }
    }

    private func capture(
        view: some View,
        appearance: NSAppearance.Name,
        size: NSSize = NSSize(width: 380, height: 440),
        scrollOffsetY: CGFloat? = nil,
        to url: URL
    ) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: appearance)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()

        // SwiftUI resolves its first layout pass on the run loop.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if let scrollOffsetY {
            let scrollView = try XCTUnwrap(
                firstScrollableView(in: hosting),
                "Expected the captured view to contain a vertical scroll view."
            )
            let documentView = try XCTUnwrap(scrollView.documentView)
            let maximumOffset = max(
                0,
                documentView.bounds.height - scrollView.contentView.bounds.height
            )
            let offset = min(max(0, scrollOffsetY), maximumOffset)
            let targetY = documentView.isFlipped
                ? documentView.bounds.minY + offset
                : documentView.bounds.minY + maximumOffset - offset
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            let scrollDeadline = Date().addingTimeInterval(0.25)
            while Date() < scrollDeadline {
                RunLoop.current.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.05)
                )
            }
        }

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 2_000, "snapshot looks empty")
    }

    private func firstScrollableView(in view: NSView) -> NSScrollView? {
        if
            let scrollView = view as? NSScrollView,
            let documentView = scrollView.documentView,
            documentView.bounds.height > scrollView.contentView.bounds.height + 1
        {
            return scrollView
        }
        for subview in view.subviews {
            if let match = firstScrollableView(in: subview) {
                return match
            }
        }
        return nil
    }
}
