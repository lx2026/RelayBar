import AppKit
import FrameKit
import SwiftUI

/// Places the window controls in the middle of the 52-point top row and reports full screen.
struct WindowChrome: NSViewRepresentable {
  @Binding var isFullScreen: Bool
  func makeNSView(context: Context) -> WindowChromeView {
    let view = WindowChromeView()
    view.placement.onFullScreenChange = { value in if isFullScreen != value { isFullScreen = value } }
    return view
  }
  func updateNSView(_ view: WindowChromeView, context: Context) {
    view.placement.onFullScreenChange = { value in if isFullScreen != value { isFullScreen = value } }
  }
  static func dismantleNSView(_ view: WindowChromeView, coordinator: ()) { view.placement.detach() }
}

final class WindowChromeView: NSView {
  let placement = WindowControlsPlacement(rowHeight: FrameMetrics.topRowHeight, controlsWidth: FrameMetrics.windowControlsWidth,
    firstCentre: FrameMetrics.inset + 6, pitch: FrameMetrics.windowControlPitch)
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    placement.attach(to: window)
    DispatchQueue.main.async { [weak self] in self?.placement.place() }
  }
}

/// Empty parts of a top row move the window, and a double click there does what the title bar's would.
struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
  func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    if event.clickCount == 2 {
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
      case "Minimize": window.performMiniaturize(nil)
      case "None": break
      default: window.performZoom(nil)
      }
      return
    }
    window.performDrag(with: event)
  }
}

/// A scroll view that keeps the overlay scroller whatever the "Show scroll bars" setting.
final class OverlayScrollView: NSScrollView {
  /// AppKit sets the style again whenever the preference changes and when a scroller is made; it always gets overlay.
  override var scrollerStyle: NSScroller.Style {
    get { super.scrollerStyle }
    set { super.scrollerStyle = .overlay }
  }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scrollerStyle = .overlay
    NotificationCenter.default.addObserver(self, selector: #selector(preferredScrollerStyleDidChange),
      name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if scrollerStyle != .overlay { scrollerStyle = .overlay }
  }
  /// Each scroll view adopts the new preferred style in its own observer, which may run after this one.
  @objc private func preferredScrollerStyleDidChange(_ notification: Notification) {
    scrollerStyle = .overlay
    DispatchQueue.main.async { [weak self] in
      if self?.scrollerStyle != .overlay { self?.scrollerStyle = .overlay }
    }
  }
}

extension View {
  /// Puts the scroll view this content sits in on the overlay scroller and keeps it there.
  func overlayScroller() -> some View { background(OverlayScrollerStyle()) }
}

private struct OverlayScrollerStyle: NSViewRepresentable {
  func makeNSView(context: Context) -> OverlayScrollerProbe { OverlayScrollerProbe() }
  func updateNSView(_ view: OverlayScrollerProbe, context: Context) { view.apply() }
}

final class OverlayScrollerProbe: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self, name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    guard window != nil else { return }
    NotificationCenter.default.addObserver(self, selector: #selector(preferredScrollerStyleDidChange),
      name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    apply()
  }
  override func layout() {
    super.layout()
    apply()
  }
  func apply() {
    guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
    scrollView.scrollerStyle = .overlay
  }
  @objc private func preferredScrollerStyleDidChange(_ notification: Notification) {
    apply()
    DispatchQueue.main.async { [weak self] in self?.apply() }
  }
}
