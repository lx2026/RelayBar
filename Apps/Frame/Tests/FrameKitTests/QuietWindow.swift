import AppKit

/// The one kind of window Frame's tests make. It never appears: it sits far outside every screen and refuses to
/// be moved back onto one, it is never key or main, and it is never ordered in front of anything. Making one also
/// stops the test process from ever activating itself.
@MainActor
final class QuietWindow: NSWindow {
  static let origin = NSPoint(x: -100_000, y: -100_000)
  private static var prepared = false

  init(size: NSSize, styleMask: NSWindow.StyleMask = [.borderless]) {
    Self.prepareTestProcess()
    super.init(contentRect: NSRect(origin: Self.origin, size: size), styleMask: styleMask, backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    animationBehavior = .none
    setFrameOrigin(Self.origin)
  }

  /// The test process may use AppKit, but may not become the active app or show a window.
  static func prepareTestProcess() {
    guard !prepared else { return }
    prepared = true
    NSApplication.shared.setActivationPolicy(.prohibited)
  }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
  override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(Self.origin) }
  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    super.setFrame(NSRect(origin: Self.origin, size: frameRect.size), display: flag)
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  override func makeKeyAndOrderFront(_ sender: Any?) {}
  override func makeKey() {}
  override func makeMain() {}
  override func orderFront(_ sender: Any?) {}
  override func orderFrontRegardless() {}
  override func orderBack(_ sender: Any?) {}
  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    if place == .out { super.order(place, relativeTo: otherWin) }
  }
  /// For a test whose drawing needs the window in the window list: ordered in behind everything, still off screen.
  func orderInOffscreen() {
    super.setFrameOrigin(Self.origin)
    super.order(.below, relativeTo: 0)
  }
}
