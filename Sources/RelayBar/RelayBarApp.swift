import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct RelayBarApp: App {
    @NSApplicationDelegateAdaptor(RelayBarAppDelegate.self) private var appDelegate
    @StateObject private var store = TunnelStore.shared

    var body: some Scene {
        MenuBarExtra {
            RelayBarRootView()
                .environmentObject(store)
        } label: {
            Label("RelayBar", systemImage: store.runningCount > 0
                  ? "arrow.left.arrow.right.circle.fill"
                  : "arrow.left.arrow.right.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class RelayBarAppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var previewWindow: NSWindow?
    private var tunnelPreviewStore: TunnelStore?
    private var tunnelPreviewDefaultsSuite: String?
    private var remoteFilesPreviewPresenter: RemoteFilesPreviewPresenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview-dark") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        } else if arguments.contains("--preview-light") {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
        if
            let livePreviewIndex = arguments.firstIndex(of: "--remote-files-live-preview"),
            arguments.indices.contains(livePreviewIndex + 1)
        {
            let sshHost = arguments[livePreviewIndex + 1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard SSHArgumentPolicy.isValidHostTarget(sshHost) else { return }

            NSApplication.shared.setActivationPolicy(.regular)
            let tunnel = Tunnel(
                name: "",
                localPort: 1,
                destinationHost: "localhost",
                destinationPort: 1,
                sshHost: sshHost
            )
            let presenter = RemoteFilesPreviewPresenter()
            remoteFilesPreviewPresenter = presenter
            RemoteFilesWindowController.shared.show(
                tunnels: [tunnel],
                presenter: presenter,
                catalog: RemoteServerCatalog()
            )
            return
        }
        if arguments.contains("--remote-files-preview") {
            NSApplication.shared.setActivationPolicy(.regular)
            let tunnels = [
                Tunnel(
                    name: "127.0.0.1:5902 Virtual Desktop",
                    localPort: 5_902,
                    destinationHost: "127.0.0.1",
                    destinationPort: 5_902,
                    sshHost: "spark-422e.local"
                ),
                Tunnel(
                    name: "Hermes Dashboard",
                    localPort: 9_119,
                    destinationHost: "127.0.0.1",
                    destinationPort: 9_119,
                    sshHost: "spark-422e.local"
                ),
                Tunnel(
                    name: "127.0.0.1:4321",
                    localPort: 4_321,
                    destinationHost: "127.0.0.1",
                    destinationPort: 4_321,
                    sshHost: "spark-422e.local"
                ),
                Tunnel(
                    name: "",
                    localPort: 3_000,
                    destinationHost: "127.0.0.1",
                    destinationPort: 3_000,
                    sshHost: "linxy97@spark-422e"
                )
            ]
            let presenter = RemoteFilesPreviewPresenter()
            remoteFilesPreviewPresenter = presenter
            RemoteFilesWindowController.shared.show(
                tunnels: tunnels,
                service: RemoteFilesPreviewService(),
                presenter: presenter,
                catalog: RemoteServerCatalog()
            )
            return
        }
        guard arguments.contains("--preview-window") else { return }
        NSApplication.shared.setActivationPolicy(.regular)

        let previewStore: TunnelStore
        if arguments.contains("--grouping-preview") {
            let suite = "RelayBar.GroupingPreview.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = TunnelStore(defaults: defaults)
            let scenario: String
            if
                let index = arguments.firstIndex(of: "--grouping-preview"),
                arguments.indices.contains(index + 1),
                !arguments[index + 1].hasPrefix("--")
            {
                scenario = arguments[index + 1]
            } else {
                scenario = "mixed"
            }
            let fixtures: [(name: String, group: String?)]
            switch scenario {
            case "empty":
                fixtures = []
            case "all-untagged", "zero-tag":
                fixtures = [
                    ("Hermes Dashboard", nil),
                    ("Virtual Desktop", nil),
                    ("Scratch", nil)
                ]
            case "one-bucket":
                fixtures = [
                    ("Hermes Dashboard", "Work"),
                    ("Virtual Desktop", "Work"),
                    ("Preview Server", "Work")
                ]
            case "all-tagged":
                fixtures = [
                    ("Hermes Dashboard", "Work"),
                    ("Virtual Desktop", "Work"),
                    ("Photos", "Personal")
                ]
            case "long-tag":
                let maximumWidthGroup = "Group "
                    + String(repeating: "🌐", count: 26)
                fixtures = [
                    ("Quarterly Dashboard", maximumWidthGroup),
                    ("Research Preview", maximumWidthGroup)
                ]
            case "many-sections":
                fixtures = [
                    ("Build Monitor", "Engineering"),
                    ("CRM", "Client Work"),
                    ("Photos", "Personal"),
                    ("Research", "Research"),
                    ("Status", "Operations"),
                    ("Preview", "Design")
                ]
            default:
                fixtures = [
                    ("Hermes Dashboard", "Work"),
                    ("Virtual Desktop", "Work"),
                    ("Photos", "Personal"),
                    ("Scratch", nil)
                ]
            }

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
            tunnelPreviewStore = store
            tunnelPreviewDefaultsSuite = suite
            previewStore = store
        } else if arguments.contains("--flexible-forwarding-preview") {
            let suite = "RelayBar.FlexibleForwardingPreview.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = TunnelStore(defaults: defaults)
            store.add(
                Tunnel(
                    name: "Development Web",
                    sshHost: "dev@example.com",
                    rules: [
                        .localTCP(
                            bindAddress: "localhost",
                            port: 3_000,
                            destinationHost: "localhost",
                            destinationPort: 3_000
                        )
                    ]
                )
            )
            store.add(
                Tunnel(
                    name: "Web, SOCKS & Preview",
                    sshHost: "bastion.example.com",
                    additionalArguments: ["-p", "2222"],
                    rules: [
                        .localTCP(
                            bindAddress: "localhost",
                            port: 8_080,
                            destinationHost: "web.internal",
                            destinationPort: 80
                        ),
                        ForwardingRule(
                            kind: .localDynamic,
                            listen: .tcp(bindAddress: "localhost", port: 1_080)
                        ),
                        ForwardingRule(
                            kind: .remote,
                            listen: .tcp(bindAddress: "localhost", port: 0),
                            destination: .tcp(host: "localhost", port: 4_321)
                        )
                    ]
                )
            )
            store.add(
                Tunnel(
                    name: "Restricted Reverse SOCKS",
                    sshHost: "gateway.example.com",
                    rules: [
                        ForwardingRule(
                            kind: .remoteDynamic,
                            listen: .tcp(bindAddress: "0.0.0.0", port: 1_081)
                        )
                    ],
                    reverseSOCKSPolicy: .allow([
                        "api.example.com:443",
                        "*.internal:8443"
                    ])
                )
            )
            tunnelPreviewStore = store
            tunnelPreviewDefaultsSuite = suite
            previewStore = store
        } else {
            previewStore = TunnelStore.shared
        }

        let rootView = RelayBarRootView()
            .environmentObject(previewStore)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "RelayBar Preview"
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        previewWindow = window
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        RemoteFilesWindowController.shared.close()
        #if DEBUG
        remoteFilesPreviewPresenter?.cleanup()
        if let tunnelPreviewDefaultsSuite {
            UserDefaults.standard.removePersistentDomain(
                forName: tunnelPreviewDefaultsSuite
            )
        }
        #endif
        TunnelStore.shared.stopAll()
    }
}

#if DEBUG
private final class RemoteFilesPreviewService: RemoteFileServing, @unchecked Sendable {
    private let stateLock = NSLock()
    private var listRequestCounts: [String: Int] = [:]

    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        try await Task.sleep(for: .milliseconds(250))

        if path.hasSuffix("/empty") {
            return []
        }
        if path.hasSuffix("/reports") {
            return [
                entry("weekly-summary.md", path: path, size: 8_420),
                entry("metrics.csv", path: path, size: 42_700)
            ]
        }
        if path.hasSuffix("/unstable") {
            if requestCount(for: path) == 2 {
                throw RemoteFileError.commandFailed("The connection was lost.")
            }
            return [
                entry("recovered-report.md", path: path, size: 7_680)
            ]
        }

        switch path {
        case "/workspace":
            throw RemoteFileError.commandFailed("The remote path wasn’t found.")
        case "/permission-denied":
            throw RemoteFileError.commandFailed(
                "Permission was denied for this server or path."
            )
        case "/host-key-failure":
            throw RemoteFileError.commandFailed(
                "SSH could not verify this server’s host key."
            )
        case "/connection-lost":
            throw RemoteFileError.commandFailed("The connection was lost.")
        default:
            break
        }

        return [
            entry("empty", path: path, kind: .directory),
            entry("reports", path: path, kind: .directory),
            entry("screenshots", path: path, kind: .directory),
            entry("unstable", path: path, kind: .directory),
            entry("dashboard.png", path: path, size: 1_258_291),
            entry(
                "quarterly-analysis-with-an-intentionally-long-filename-for-layout-verification.csv",
                path: path,
                size: 842_700
            ),
            entry("README.md", path: path, size: 4_096),
            entry("permission-denied.bin", path: path, size: 4_000_000),
            entry("results.zip", path: path, size: 3_565_158),
            entry("slow-download.bin", path: path, size: 50_000_000)
        ]
    }

    func download(
        server: RemoteServer,
        entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let total = entry.size ?? 2_000_000
        let stepCount = entry.name == "slow-download.bin" ? 100 : 20
        for step in 1...stepCount {
            try Task.checkCancellation()
            progress(total * Int64(step) / Int64(stepCount))
            try await Task.sleep(for: .milliseconds(100))
            if entry.name == "permission-denied.bin", step == 5 {
                throw RemoteFileError.commandFailed(
                    "Permission was denied for this server or path."
                )
            }
        }
        if entry.isDirectory {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } else {
            try Data("RelayBar preview download".utf8).write(to: destination)
        }
    }

    private func requestCount(for path: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let count = (listRequestCounts[path] ?? 0) + 1
        listRequestCounts[path] = count
        return count
    }

    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayBarPreviewReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent(entry.name)
        if entry.isPreviewableMarkdown {
            try Data(markdownPreview.utf8).write(to: destination)
        } else {
            try makePreviewImage(at: destination)
        }
        return destination
    }

    private func entry(
        _ name: String,
        path: String,
        kind: RemoteFileEntry.Kind = .file,
        size: Int64? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: RemotePath.joining(path, name),
            kind: kind,
            size: size,
            modificationText: "Jul 24 00:20"
        )
    }

    private func makePreviewImage(at url: URL) throws {
        let width = 1_200
        let height = 720
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw RemoteFileError.unsupportedImage
        }

        context.setFillColor(CGColor(red: 0.055, green: 0.065, blue: 0.085, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1))
        context.fill(CGRect(x: 70, y: 70, width: 1_060, height: 580))
        context.setStrokeColor(CGColor(red: 0.18, green: 0.50, blue: 0.98, alpha: 1))
        context.setLineWidth(8)
        context.move(to: CGPoint(x: 120, y: 210))
        context.addCurve(
            to: CGPoint(x: 1_080, y: 500),
            control1: CGPoint(x: 390, y: 570),
            control2: CGPoint(x: 720, y: 160)
        )
        context.strokePath()

        for index in 0..<8 {
            let barHeight = CGFloat(110 + ((index * 47) % 260))
            context.setFillColor(CGColor(red: 0.18, green: 0.50, blue: 0.98, alpha: 0.55))
            context.fill(
                CGRect(
                    x: CGFloat(155 + index * 115),
                    y: 120,
                    width: 58,
                    height: barHeight
                )
            )
        }

        guard
            let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw RemoteFileError.unsupportedImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RemoteFileError.unsupportedImage
        }
    }

    private var markdownPreview: String {
        """
        ---
        status: ready
        environment: production
        reviewers:
          - Product
          - Security
        summary: |
          Safe remote reading.
          No vault indexing.
        ---

        # RelayBar remote report

        This is a **read-only** Markdown preview from the selected server.
        Text remains selectable, [safe web links](https://example.com) open only when clicked,
        and a [remote setup guide](Guides/Setup.md#Install) stays inside the vault boundary. ^preview-summary

        > [!warning] Safe by default
        > Remote HTML is never executed, and images are not loaded automatically.

        > [!faq]- Folded in the source
        > RelayBar keeps remote content visible in its continuous reading view.
        >
        > > [!todo]+ Nested check
        > > Fold markers and nesting stay clear without adding disclosure controls.

        ## Delivery status

        | Capability | State |
        | --- | --- |
        | Exact-path browsing | Ready |
        | Image preview | Ready |
        | Markdown rendering | Ready |
        | Table-safe alias | [[Operations\\|Runbook]] |

        - [x] GitHub-flavored tables
        - [x] Task lists and strikethrough
        - [?] Custom Obsidian task status
        - [ ] Remote editing

        The compatibility layer preserves ==important notes==, shows [[Operations|wiki links]]
        without fetching them, and lists footnotes at the end.[^safety]
        The #production/relaybar tag stays visible without indexing the remote vault.

        Inline math renders natively: $E = mc^2$.

        $$
        \\int_0^1 x^2\\,dx = \\frac{1}{3}
        $$

        ```swift
        let service = RemoteFilesService()
        await service.open(path: "/srv/app/output")
        let lifecycle = ["download", "decode", "render", "review"].map { stage in "\\(stage): cancellation-safe and independently bounded" }.joined(separator: " → ")
        ```

        ```mermaid
        graph LR
          Remote --> Preview
        ```

        ![[private-diagram.png]]

        ![A remote chart that is intentionally not fetched|640x360][review-chart]

        [review-chart]: https://example.com/chart.png

        %% This reading-mode comment is intentionally hidden. %%

        [^safety]: Linked remote content is never fetched implicitly.
          Two-space continuation lines stay with the footnote.

        <script
          data-mode="literal">
        alert("This is displayed as text, never executed.")
        </script>

        [<style>HTML-looking link label</style>](https://example.com)
        """
    }
}

@MainActor
private final class RemoteFilesPreviewPresenter: RemoteFilePresenting {
    private let rootURL: URL

    init() {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RelayBarRemoteFilesUIReview-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func chooseDestination(for entry: RemoteFileEntry) -> URL? {
        rootURL.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
    }

    func revealInFinder(_ destination: URL) {
        // The review fixture stays isolated from Finder and external applications.
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
#endif
