import AppKit
import Combine
import SwiftUI

enum RemoteFilesWindowSizing {
    static let workspace = NSSize(width: 920, height: 600)
    static let browser = NSSize(width: 920, height: 600)
    static let browserMinimum = NSSize(width: 760, height: 440)
    static let previewPreferred = NSSize(width: 980, height: 640)
    static let previewMinimum = NSSize(width: 760, height: 440)

    static func previewSize(from current: NSSize) -> NSSize {
        NSSize(
            width: max(current.width, previewPreferred.width),
            height: max(current.height, previewPreferred.height)
        )
    }
}

@MainActor
final class RemoteFilesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private(set) var model: RemoteFilesModel?
    var onClose: (() -> Void)?
    private var screenObserver: AnyCancellable?

    func show(model: RemoteFilesModel) {
        if let window {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let view = RemoteFilesView(model: model)
            .onReceive(NotificationCenter.default.publisher(for: .frameRemoteHistoryChanged)) { _ in model.refreshSharedHistory() }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: RemoteFilesWindowSizing.workspace),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remote Files"
        window.contentMinSize = RemoteFilesWindowSizing.browserMinimum
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
        if let window {
            window.close()
        }
    }

    /// Cancelling starts as the window closes; whoever owns the model awaits its shutdown.
    func windowWillClose(_ notification: Notification) {
        guard let closingModel = model else {
            clearActiveWindow()
            return
        }
        clearActiveWindow()
        closingModel.cancelAll()
        onClose?()
    }

    private func resizeWindow(for screen: RemoteFilesModel.Screen) {
        guard let window else { return }

        switch screen {
        case .welcome:
            window.styleMask.insert(.resizable)
            window.contentMinSize = RemoteFilesWindowSizing.browserMinimum

        case .browser:
            window.styleMask.insert(.resizable)
            window.contentMinSize = RemoteFilesWindowSizing.browserMinimum

        case .preview:
            window.styleMask.insert(.resizable)
            window.contentMinSize = RemoteFilesWindowSizing.previewMinimum
            let current = window.contentView?.frame.size
                ?? window.contentRect(forFrameRect: window.frame).size
            let target = RemoteFilesWindowSizing.previewSize(from: current)
            resize(window, to: target, centersWindow: false)
        }
    }

    private func resize(
        _ window: NSWindow,
        to target: NSSize,
        centersWindow: Bool
    ) {
        guard window.contentView?.frame.size != target else { return }
        let originalCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.setContentSize(target)
        if centersWindow {
            window.center()
            return
        }

        let proposedFrame = NSRect(
            x: originalCenter.x - window.frame.width / 2,
            y: originalCenter.y - window.frame.height / 2,
            width: window.frame.width,
            height: window.frame.height
        )
        if let screen = window.screen {
            window.setFrame(window.constrainFrameRect(proposedFrame, to: screen), display: true)
        } else {
            window.setFrameOrigin(proposedFrame.origin)
        }
    }

    private func clearActiveWindow() {
        screenObserver = nil
        model = nil
        window = nil
    }
}
