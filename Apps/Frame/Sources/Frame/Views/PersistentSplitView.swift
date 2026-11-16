import AppKit
import FrameKit
import SwiftUI

/// Native splitters provide resize cursors and saved pane sizes.
struct PersistentSplitView<First: View, Second: View>: NSViewControllerRepresentable {
  let name: String
  let vertical: Bool
  let minimumFirst: CGFloat
  let minimumSecond: CGFloat
  let first: First
  let second: Second

  func makeNSViewController(context: Context) -> SplitController {
    let controller = SplitController()
    controller.splitView = PreviewSplitView()
    controller.splitView.isVertical = vertical
    controller.splitView.dividerStyle = .thin
    let isSidebar = name.contains("Sidebar")
    let isInfo = name.contains("Info")
    controller.splitView.autosaveName = isSidebar ? name + ".v2" : name
    controller.splitView.setAccessibilityLabel(vertical ? "Preview panel width" : "Preview image height")
    let firstHost = NSHostingController(rootView: styled(first))
    let secondHost = NSHostingController(rootView: styled(second))
    firstHost.sizingOptions = []
    secondHost.sizingOptions = []
    firstHost.view.setFrameSize(NSSize(width: isSidebar ? 260 : 640, height: 320))
    secondHost.view.setFrameSize(NSSize(width: isInfo ? 300 : 480, height: 300))
    let firstItem = NSSplitViewItem(viewController: firstHost)
    let secondItem = NSSplitViewItem(viewController: secondHost)
    firstItem.minimumThickness = minimumFirst
    secondItem.minimumThickness = minimumSecond
    firstItem.preferredThicknessFraction = name.contains("Sidebar") ? 0.20 : name.contains("Info") ? 0.75 : vertical ? 0.56 : 0.53
    secondItem.preferredThicknessFraction = 1 - firstItem.preferredThicknessFraction
    // Stay below AppKit's divider-drag priority (490), or dragging is blocked.
    // Window growth belongs to the preview; the sidebar keeps its chosen width.
    if isSidebar { firstItem.holdingPriority = NSLayoutConstraint.Priority(260) }
    else { secondItem.holdingPriority = NSLayoutConstraint.Priority(260) }
    controller.addSplitViewItem(firstItem)
    controller.addSplitViewItem(secondItem)
    return controller
  }

  func updateNSViewController(_ controller: SplitController, context: Context) {
    (controller.splitViewItems[0].viewController as? NSHostingController<AnyView>)?.rootView = styled(first)
    (controller.splitViewItems[1].viewController as? NSHostingController<AnyView>)?.rootView = styled(second)
    if controller.splitViewItems[0].minimumThickness != minimumFirst {
      controller.splitViewItems[0].minimumThickness = minimumFirst
    }
    if controller.splitViewItems[1].minimumThickness != minimumSecond {
      controller.splitViewItems[1].minimumThickness = minimumSecond
    }
  }

  private func styled<Content: View>(_ content: Content) -> AnyView {
    AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundStyle(FramePalette.ink).tint(FramePalette.ink).background(FramePalette.paper))
  }
}

final class SplitController: NSSplitViewController {
  override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                          forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
    return proposedEffectiveRect.insetBy(dx: splitView.isVertical ? -4 : 0, dy: splitView.isVertical ? 0 : -4)
  }
}

/// A quiet but grabbable divider: thin rules are otherwise difficult to discover.
final class PreviewSplitView: NSSplitView {
  private var dragOffset: CGFloat?
  override var dividerThickness: CGFloat { 6 }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var handleRect: NSRect {
    guard let first = arrangedSubviews.first else { return .zero }
    return isVertical
      ? NSRect(x: first.frame.maxX, y: bounds.minY, width: dividerThickness, height: bounds.height)
      : NSRect(x: bounds.minX, y: first.frame.maxY, width: bounds.width, height: dividerThickness)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if handleRect.contains(local) { return self }
    return super.hitTest(point)
  }

  // Keep tracking in the normal responder loop when embedded in SwiftUI hosts.
  // AppKit still constrains the actual divider position and persists the panes.
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard handleRect.contains(point) else { super.mouseDown(with: event); return }
    dragOffset = isVertical ? point.x - handleRect.minX : point.y - handleRect.minY
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragOffset else { super.mouseDragged(with: event); return }
    let point = convert(event.locationInWindow, from: nil)
    setPosition((isVertical ? point.x : point.y) - dragOffset, ofDividerAt: 0)
  }

  override func mouseUp(with event: NSEvent) {
    if dragOffset != nil { dragOffset = nil } else { super.mouseUp(with: event) }
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(handleRect, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
  }

  override func drawDivider(in rect: NSRect) {
    FrameColors.panel.setFill()
    rect.fill()
    NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
    let grip = isVertical
      ? NSRect(x: rect.midX - 1, y: rect.midY - 14, width: 2, height: 28)
      : NSRect(x: rect.midX - 14, y: rect.midY - 1, width: 28, height: 2)
    NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
  }
}
