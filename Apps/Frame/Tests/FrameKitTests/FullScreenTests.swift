import AppKit
import XCTest
@testable import FrameKit

/// Leaving full screen, however it happens, must leave the top row usable. Run on a window that never appears,
/// with the window's own full-screen notifications posted to the code that reacts to them.
@MainActor
final class FullScreenTests: XCTestCase {
  private func window() -> QuietWindow {
    let window = QuietWindow(size: NSSize(width: 1_280, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    return window
  }
  private func titleBar(_ window: NSWindow) throws -> NSView {
    try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview?.superview)
  }
  private func centre(_ view: NSView) -> NSPoint {
    let frame = view.convert(view.bounds, to: nil)
    return NSPoint(x: frame.midX, y: frame.midY)
  }
  private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

  func testControlsSitInTheTopRowAndTheTitleBarCoversNothingElse() throws {
    let window = window()
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1_280, height: 800))
    // A control in the top row just past the window controls, like the Files/Icons switch.
    let control = NSButton(frame: NSRect(x: 84, y: 800 - 40, width: 60, height: 28))
    content.addSubview(control)
    window.contentView = content
    let placement = WindowControlsPlacement()
    placement.attach(to: window)
    defer { placement.detach() }
    let bar = try titleBar(window)
    XCTAssertEqual(bar.frame, NSRect(x: 0, y: 748, width: 78, height: 52), "The title bar is no wider than its buttons")
    XCTAssertEqual(centre(try XCTUnwrap(window.standardWindowButton(.closeButton))), NSPoint(x: 22, y: 774))
    XCTAssertEqual(centre(try XCTUnwrap(window.standardWindowButton(.zoomButton))).x, 62)
    let root = try XCTUnwrap(window.contentView?.superview)
    XCTAssertTrue(root.hitTest(centre(control)) === control, "A click in the top row reaches its control")
    XCTAssertTrue(root.hitTest(centre(try XCTUnwrap(window.standardWindowButton(.closeButton)))) === window.standardWindowButton(.closeButton))
  }

  func testPlacementIsRestoredAfterAppKitLaysTheTitleBarOutAgain() throws {
    let window = window()
    let placement = WindowControlsPlacement()
    placement.attach(to: window)
    defer { placement.detach() }
    let bar = try titleBar(window)
    // What AppKit does on leaving full screen or resizing: a full-width, 28-point title bar.
    bar.frame = NSRect(x: 0, y: 772, width: 1_280, height: 28)
    XCTAssertEqual(bar.frame, NSRect(x: 0, y: 748, width: 78, height: 52))
    let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
    close.setFrameOrigin(NSPoint(x: 7, y: 6))
    XCTAssertEqual(centre(close), NSPoint(x: 22, y: 774))
    window.setContentSize(NSSize(width: 960, height: 640))
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    XCTAssertEqual(bar.frame, NSRect(x: 0, y: 588, width: 78, height: 52))
    XCTAssertEqual(centre(close), NSPoint(x: 22, y: 614))
  }

  func testLeavingFullScreenIsReported() async throws {
    let window = window()
    let placement = WindowControlsPlacement()
    var reports: [Bool] = []
    placement.onFullScreenChange = { reports.append($0) }
    placement.attach(to: window)
    defer { placement.detach() }
    await settle()
    XCTAssertEqual(reports, [false])
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    await settle()
    XCTAssertEqual(reports, [false], "Only a change is reported")
  }

  func testTheFullScreenViewerEndsWithFullScreenHoweverItEnds() async throws {
    let store = LibraryStore(defaults: UserDefaults(suiteName: "FrameFullScreen.\(UUID())")!)
    let window = window()
    store.beginFocusMode(watching: window)
    XCTAssertTrue(store.isFocusMode)
    NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    XCTAssertFalse(store.isFocusMode, "The green button and every other way out end it")

    store.beginFocusMode(watching: window)
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    XCTAssertFalse(store.isFocusMode)

    store.focusEntryTimeout = 0.05
    store.beginFocusMode(watching: window)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertFalse(store.isFocusMode, "A window that never became full screen does not keep the viewer")

    store.focusEntryTimeout = 0.05
    store.beginFocusMode(watching: window)
    NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertTrue(store.isFocusMode, "Once full screen, it lasts until full screen ends")
    store.fullScreenDidChange(false)
    XCTAssertFalse(store.isFocusMode)
    await store.shutdown()
  }
}
