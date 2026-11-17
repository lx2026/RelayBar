import AppKit
import FrameKit
import SwiftUI

/// The library and reader columns. A native splitter gives the resize cursor and remembers the library's width.
struct ColumnSplitView<First: View, Second: View>: NSViewControllerRepresentable {
  static var autosaveName: String { "Frame.Workspace.Sidebar.v2" }
  static var minimumFirst: CGFloat { 200 }
  static var maximumFirst: CGFloat { 420 }
  static var defaultFirst: CGFloat { 260 }
  let first: First
  let second: Second

  func makeNSViewController(context: Context) -> SplitController {
    let controller = SplitController()
    controller.splitView = ColumnDividerView()
    controller.splitView.isVertical = true
    controller.splitView.dividerStyle = .thin
    controller.splitView.autosaveName = Self.autosaveName
    controller.splitView.setAccessibilityLabel("Folders width")
    let firstHost = NSHostingController(rootView: styled(first))
    let secondHost = NSHostingController(rootView: styled(second))
    firstHost.sizingOptions = []
    secondHost.sizingOptions = []
    firstHost.view.setFrameSize(NSSize(width: Self.defaultFirst, height: 600))
    secondHost.view.setFrameSize(NSSize(width: 1_020, height: 600))
    let firstItem = NSSplitViewItem(viewController: firstHost)
    let secondItem = NSSplitViewItem(viewController: secondHost)
    firstItem.minimumThickness = Self.minimumFirst
    firstItem.maximumThickness = Self.maximumFirst
    secondItem.minimumThickness = 480
    firstItem.preferredThicknessFraction = 0.2
    secondItem.preferredThicknessFraction = 0.8
    // Stay below AppKit's divider-drag priority (490), or dragging is blocked.
    // Window growth belongs to the reader; the library keeps its chosen width.
    firstItem.holdingPriority = NSLayoutConstraint.Priority(260)
    controller.addSplitViewItem(firstItem)
    controller.addSplitViewItem(secondItem)
    return controller
  }

  func updateNSViewController(_ controller: SplitController, context: Context) {
    (controller.splitViewItems[0].viewController as? NSHostingController<AnyView>)?.rootView = styled(first)
    (controller.splitViewItems[1].viewController as? NSHostingController<AnyView>)?.rootView = styled(second)
  }

  private func styled<Content: View>(_ content: Content) -> AnyView {
    AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundStyle(FramePalette.ink).tint(FramePalette.ink).ignoresSafeArea())
  }
}

final class SplitController: NSSplitViewController {
  override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                          forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
    proposedEffectiveRect.insetBy(dx: -ColumnDividerView.grabOutset, dy: 0)
  }
}

/// A hairline between the columns with a comfortable invisible handle on either side of it.
final class ColumnDividerView: NSSplitView {
  static let grabOutset: CGFloat = 4
  private var dragOffset: CGFloat?
  override var dividerThickness: CGFloat { 1 }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var handleRect: NSRect {
    guard let first = arrangedSubviews.first else { return .zero }
    return NSRect(x: first.frame.maxX - Self.grabOutset, y: bounds.minY,
                  width: dividerThickness + Self.grabOutset * 2, height: bounds.height)
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
    dragOffset = point.x - (handleRect.minX + Self.grabOutset)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragOffset else { super.mouseDragged(with: event); return }
    let point = convert(event.locationInWindow, from: nil)
    setPosition(point.x - dragOffset, ofDividerAt: 0)
    window?.invalidateCursorRects(for: self)
  }

  override func mouseUp(with event: NSEvent) {
    if dragOffset != nil { dragOffset = nil } else { super.mouseUp(with: event) }
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(handleRect, cursor: .resizeLeftRight)
  }

  override func drawDivider(in rect: NSRect) {
    FrameColors.panel.setFill()
    rect.fill()
    FrameColors.line.setFill()
    rect.fill(using: .sourceOver)
  }
}
