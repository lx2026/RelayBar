import AppKit

/// The window RelayBar's and the shared package's tests make. It never appears: every frame it is given is moved far
/// outside every screen, it is never key or main, and a request to order it in puts it behind everything, still off
/// screen. Making one also stops the test process from ever activating itself.
///
/// Frames keep their size and their offsets from each other, so a test can still check that a window grows downwards
/// from a fixed title bar.
@MainActor
open class QuietWindow: NSWindow {
    /// Where a window made with `init(size:)` sits.
    public static let origin = NSPoint(x: -100_000, y: -100_000)
    private static var prepared = false

    /// A window of this content size at `origin`.
    public convenience init(size: NSSize, styleMask: NSWindow.StyleMask = [.borderless]) {
        self.init(contentRect: NSRect(origin: Self.origin, size: size), styleMask: styleMask, backing: .buffered, defer: false)
    }

    public override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                         backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        Self.prepareTestProcess()
        super.init(contentRect: Self.offscreen(contentRect), styleMask: style, backing: backingStoreType, defer: flag)
        Self.quieten(self)
    }

    /// The test process may use AppKit, but may not become the active app or show a window.
    public static func prepareTestProcess() {
        guard !prepared else { return }
        prepared = true
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// A frame far outside every screen: one already there is kept, any other is moved there whole.
    public static func offscreen(_ rect: NSRect) -> NSRect {
        rect.maxX < -50_000 && rect.maxY < -50_000 ? rect : rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Settings shared by every quiet window, including a test's own subclass of an app's window.
    public static func quieten(_ window: NSWindow) {
        prepareTestProcess()
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior.insert([.transient, .ignoresCycle])
    }

    open override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { Self.offscreen(frameRect) }
    open override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(Self.offscreen(NSRect(origin: point, size: frame.size)).origin)
    }
    open override func setFrameTopLeftPoint(_ point: NSPoint) {
        setFrameOrigin(NSPoint(x: point.x, y: point.y - frame.height))
    }
    open override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(Self.offscreen(frameRect), display: flag)
    }
    open override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(Self.offscreen(frameRect), display: displayFlag, animate: false)
    }

    /// For an opt-in test whose key events must reach a responder through the app: the window may become the app's
    /// key window, but it is still never ordered in front and the process still cannot activate.
    public var allowsKey = false

    open override func center() {}
    open override var canBecomeKey: Bool { allowsKey }
    open override var canBecomeMain: Bool { false }
    open override func makeKey() { if allowsKey { super.makeKey() } }
    open override func makeMain() {}
    open override func makeKeyAndOrderFront(_ sender: Any?) { orderInOffscreen() }
    open override func orderFront(_ sender: Any?) { orderInOffscreen() }
    open override func orderFrontRegardless() { orderInOffscreen() }
    open override func orderBack(_ sender: Any?) { orderInOffscreen() }
    open override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out { super.order(.out, relativeTo: otherWin) } else { orderInOffscreen() }
    }
    open override func toggleFullScreen(_ sender: Any?) {}

    /// For a test whose drawing needs the window in the window list: ordered in behind everything, still off screen.
    public func orderInOffscreen() {
        super.setFrame(Self.offscreen(frame), display: false)
        super.order(.below, relativeTo: 0)
    }
}
