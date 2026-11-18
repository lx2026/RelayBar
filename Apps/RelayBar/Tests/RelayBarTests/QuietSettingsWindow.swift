import AppKit
import CompositionFixtures
@testable import RelayBar

/// The Settings window with its own key handling, made as quiet as `QuietWindow`: off every screen, never key or
/// main, and ordered in only behind everything.
@MainActor
final class QuietSettingsWindow: SettingsWindow {
    required init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        QuietWindow.prepareTestProcess()
        super.init(contentRect: QuietWindow.offscreen(contentRect), styleMask: style, backing: backingStoreType, defer: flag)
        QuietWindow.quieten(self)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        QuietWindow.offscreen(frameRect)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(QuietWindow.offscreen(NSRect(origin: point, size: frame.size)).origin)
    }
    override func setFrameTopLeftPoint(_ point: NSPoint) {
        setFrameOrigin(NSPoint(x: point.x, y: point.y - frame.height))
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(QuietWindow.offscreen(frameRect), display: flag)
    }
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(QuietWindow.offscreen(frameRect), display: displayFlag, animate: false)
    }
    override func center() {}
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() {}
    override func makeMain() {}
    override func makeKeyAndOrderFront(_ sender: Any?) { orderInOffscreen() }
    override func orderFront(_ sender: Any?) { orderInOffscreen() }
    override func orderFrontRegardless() { orderInOffscreen() }
    override func orderBack(_ sender: Any?) { orderInOffscreen() }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out { super.order(.out, relativeTo: otherWin) } else { orderInOffscreen() }
    }
    override func toggleFullScreen(_ sender: Any?) {}

    func orderInOffscreen() {
        super.setFrame(QuietWindow.offscreen(frame), display: false)
        super.order(.below, relativeTo: 0)
    }
}
