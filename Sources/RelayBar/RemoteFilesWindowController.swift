import AppKit
import Combine
import SwiftUI

@MainActor
final class RemoteFilesWindowController: NSObject, NSWindowDelegate {
    static let shared = RemoteFilesWindowController()

    private var window: NSWindow?
    private var model: RemoteFilesModel?
    private var screenObserver: AnyCancellable?
    private let serverCatalog = RemoteServerCatalog.appDefault()

    func show(
        tunnels: [Tunnel],
        service: RemoteFileServing? = nil,
        presenter: RemoteFilePresenting? = nil,
        catalog: RemoteServerCatalog? = nil
    ) {
        if let window, let model {
            model.updateTunnels(tunnels)
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let model = RemoteFilesModel(
            tunnels: tunnels,
            service: service ?? SFTPRemoteFileService(),
            presenter: presenter,
            serverCatalog: catalog ?? serverCatalog
        )
        let view = RemoteFilesView(model: model)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: launcherSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remote Files"
        window.contentMinSize = launcherSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: view)
        window.center()

        screenObserver = model.$screen
            .removeDuplicates()
            .sink { [weak self] screen in
                Task { @MainActor [weak self] in
                    self?.resizeWindow(for: screen)
                }
            }

        self.model = model
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        model?.cancelAll()
        window?.close()
        clear()
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancelAll()
        clear()
    }

    private var launcherSize: NSSize {
        NSSize(width: 360, height: 300)
    }

    private var browserSize: NSSize {
        NSSize(width: 780, height: 520)
    }

    private func resizeWindow(for screen: RemoteFilesModel.Screen) {
        guard let window else { return }
        if screen == .preview {
            return
        }
        if screen == .browser, window.styleMask.contains(.resizable) {
            return
        }
        let target = screen == .launcher ? launcherSize : browserSize
        if screen == .launcher {
            window.styleMask.remove(.resizable)
        } else {
            window.styleMask.insert(.resizable)
        }
        window.contentMinSize = screen == .launcher
            ? launcherSize
            : NSSize(width: 620, height: 400)
        guard window.contentView?.frame.size != target else { return }
        window.setContentSize(target)
        window.center()
    }

    private func clear() {
        screenObserver = nil
        model = nil
        window = nil
    }
}
