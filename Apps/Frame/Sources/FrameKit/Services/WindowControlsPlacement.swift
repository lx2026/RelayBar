import AppKit

/// Keeps a window's close, minimise and zoom buttons in the middle of a taller top row, and keeps the title bar
/// that holds them no wider than the buttons, so no title-bar view lies over the row's own controls.
/// AppKit lays the title bar out again, or rebuilds it, on resizing, key changes and leaving full screen;
/// every such change is followed, including views that replace the ones seen before.
@MainActor public final class WindowControlsPlacement {
  public let rowHeight: CGFloat
  /// The width the controls occupy from the window's leading edge, their own inset included.
  public let controlsWidth: CGFloat
  /// Where the first button's centre sits from the leading edge, and the distance between button centres.
  public let firstCentre: CGFloat
  public let pitch: CGFloat
  /// Called, after the change, when the window enters or leaves full screen by any means.
  public var onFullScreenChange: ((Bool) -> Void)?
  private weak var window: NSWindow?
  private var windowObservers: [NSObjectProtocol] = []
  private var viewObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
  private var placing = false
  private var reportedFullScreen: Bool?

  public init(rowHeight: CGFloat = 52, controlsWidth: CGFloat = 78, firstCentre: CGFloat = 22, pitch: CGFloat = 20) {
    self.rowHeight = rowHeight
    self.controlsWidth = controlsWidth
    self.firstCentre = firstCentre
    self.pitch = pitch
  }

  public func attach(to window: NSWindow?) {
    guard window !== self.window else { return }
    detach()
    guard let window else { return }
    self.window = window
    let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
      NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
      NSWindow.didChangeScreenNotification]
    for name in names {
      windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.place() }
      })
    }
    place()
  }

  public func detach() {
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    viewObservers.values.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []; viewObservers = [:]
    window = nil; reportedFullScreen = nil
  }

  /// The title-bar views now holding the buttons: the buttons, the bar and its container.
  private func titleBarViews(of window: NSWindow) -> (buttons: [NSButton], bar: NSView, container: NSView)? {
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
    guard let bar = buttons.first?.superview, let container = bar.superview else { return nil }
    return (buttons, bar, container)
  }

  public func place() {
    guard !placing, let window else { return }
    placing = true
    defer { placing = false }
    let fullScreen = window.styleMask.contains(.fullScreen)
    if reportedFullScreen != fullScreen {
      reportedFullScreen = fullScreen
      let report = onFullScreenChange
      DispatchQueue.main.async { report?(fullScreen) }
    }
    // In full screen the controls live in the system's own title bar above the window.
    guard !fullScreen, let views = titleBarViews(of: window) else { return }
    follow([views.container, views.bar] + views.buttons)
    let frame = NSRect(x: 0, y: window.frame.height - rowHeight, width: controlsWidth, height: rowHeight)
    if views.container.frame != frame { views.container.frame = frame }
    if views.bar.frame != views.container.bounds { views.bar.frame = views.container.bounds }
    for (index, button) in views.buttons.enumerated() {
      let size = button.frame.size
      let origin = NSPoint(x: (firstCentre + CGFloat(index) * pitch - size.width / 2).rounded(),
                           y: ((rowHeight - size.height) / 2).rounded())
      if button.frame.origin != origin { button.setFrameOrigin(origin) }
    }
  }

  /// Watches the frames of these views, adding views AppKit has just made in place of earlier ones.
  private func follow(_ views: [NSView]) {
    let current = Set(views.map(ObjectIdentifier.init))
    for (id, observer) in viewObservers where !current.contains(id) {
      NotificationCenter.default.removeObserver(observer)
      viewObservers.removeValue(forKey: id)
    }
    for view in views where viewObservers[ObjectIdentifier(view)] == nil {
      view.postsFrameChangedNotifications = true
      viewObservers[ObjectIdentifier(view)] = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
          MainActor.assumeIsolated { self?.place() }
        }
    }
  }
}
