import AppKit
import CompositionFixtures
import SwiftUI
import XCTest
@testable import RelayBar

/// The popover scrolls only vertically. Each check runs as hosted, with the legacy scroller held in force,
/// back on the overlay scroller, after a one-off reset to the legacy scroller, and after the window is shown
/// again. The style is changed on the backing scroll view itself, with no notification, as when the overlay
/// override loses, so these checks do not depend on the "Show scroll bars" setting.
@MainActor
final class PopoverScrollingTests: XCTestCase {
    func testNestedBoundsNotificationDoesNotReenterScrollCorrection() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = ReentrantClipView(frame: scroll.bounds)
        scroll.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        scroll.documentView = document
        let observer = VerticalScrollingOnlyView()
        document.addSubview(observer)
        observer.apply()

        clip.observeCorrections = true
        clip.setBoundsOrigin(NSPoint(x: 20, y: 30))
        XCTAssertEqual(clip.maximumCorrectionDepth, 1)
        XCTAssertEqual(clip.bounds.origin, NSPoint(x: 0, y: 30))
    }

    func testListAndEditorHaveNoHorizontalRangeWhileTheLegacyScrollerIsInForce() throws {
        let store = try makeStore()
        for index in 0..<14 {
            store.add(Tunnel(
                name: "Tunnel \(index)", localPort: 8_000 + index, destinationHost: "localhost",
                destinationPort: 3_000 + index, sshHost: "host-\(index).example.com",
                groupTag: index.isMultiple(of: 2) ? "Work" : nil
            ))
        }
        let editTunnel = try XCTUnwrap(store.tunnels.first)

        try assertScrollsOnlyVertically(
            RelayBarRootView().environmentObject(store),
            inset: RelayBarPopoverLayout.listHorizontalInset, "list"
        )
        try assertScrollsOnlyVertically(
            TunnelEditorView(tunnel: editTunnel, availableGroups: ["Work"], onCancel: {}, onSave: { _ in }),
            inset: RelayBarPopoverLayout.contentInset, "editor"
        )
    }

    /// Long names, hosts, failure messages, service labels, multi-rule mappings and group names, a hovered
    /// row and long field values truncate or wrap inside the popover rather than widen it.
    func testLongNamesHostsAndMessagesStayInsideThePopover() throws {
        let store = try makeStore()
        let longName = String(repeating: "Name", count: 30)
        let longHost = "deploy@" + String(repeating: "bastion-", count: 12) + "example.com"
        let longDestination = String(repeating: "service.", count: 12) + "internal"
        let longGroup = String(repeating: "G", count: TunnelGroupTag.maximumCharacterCount)
        let longMessage = "ssh: connect to host " + String(repeating: "unreachable-", count: 10)
            + "example.com port 22: Operation timed out"
        let socketPath = "/tmp/" + String(repeating: "socket-directory/", count: 8) + "relay.sock"

        func web(_ suffix: String, _ port: Int, group: String? = longGroup) -> Tunnel {
            Tunnel(name: longName + suffix, localPort: port, destinationHost: longDestination,
                   destinationPort: 3_000, sshHost: longHost, groupTag: group)
        }
        let failed = web("", 18_000)
        let retrying = web(" retrying", 18_001)
        let labelled = web(" labelled", 18_002, group: nil)
        let multiRule = Tunnel(
            name: longName + " rules", sshHost: longHost,
            rules: [
                .localTCP(bindAddress: "127.0.0.1", port: 18_003, destinationHost: longDestination,
                          destinationPort: 5_432),
                ForwardingRule(kind: .remote, listen: .unix(path: socketPath),
                               destination: .tcp(host: longDestination, port: 8_443)),
                ForwardingRule(kind: .localDynamic, listen: .tcp(bindAddress: "localhost", port: 18_004)),
                ForwardingRule(kind: .remoteDynamic, listen: .tcp(bindAddress: "localhost", port: 18_005))
            ],
            reverseSOCKSPolicy: .allow([longDestination + ":443", longDestination + ":8443"]),
            groupTag: longGroup
        )
        let reverseSOCKS = Tunnel(
            name: longName + " reverse", sshHost: longHost,
            rules: [ForwardingRule(kind: .remoteDynamic, listen: .tcp(bindAddress: "localhost", port: 18_006))],
            reverseSOCKSPolicy: .allow([longDestination + ":443"])
        )
        // Enough rows that the list overflows and a legacy scroller appears.
        let fixtures = [failed, retrying, labelled, multiRule, reverseSOCKS]
            + (0..<5).map { web(" \($0)", 18_010 + $0, group: $0.isMultiple(of: 2) ? nil : longGroup) }
        for tunnel in fixtures { store.add(tunnel) }
        XCTAssertEqual(store.tunnels.count, fixtures.count, "every fixture is a valid profile")
        store.setPreviewPhase(.failed(longMessage), for: failed)
        store.setPreviewPhase(.retrying(attempt: 12, maxAttempts: 100, delay: 3_600, message: longMessage),
                              for: retrying)
        store.setPreviewPhase(.running, for: labelled)
        store.setPreviewPhase(.running, for: multiRule)
        let labels = [try XCTUnwrap(labelled.rules.first).id: ServiceLabel(name: longName, isResponding: true)]

        try assertScrollsOnlyVertically(
            RelayBarRootView(serviceLabels: labels)
                .environmentObject(store)
                .environment(\.previewHoveredTunnel, failed.id),
            inset: RelayBarPopoverLayout.listHorizontalInset, "list"
        )
        for (name, tunnel) in [("editor with long values", failed), ("editor with every rule kind", multiRule)] {
            try assertScrollsOnlyVertically(
                TunnelEditorView(tunnel: tunnel, availableGroups: [longGroup], onCancel: {}, onSave: { _ in }),
                inset: RelayBarPopoverLayout.contentInset, name
            )
        }
    }

    // MARK: Helpers

    private func makeStore() throws -> TunnelStore {
        let suite = "RelayBarPopoverScrolling.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return TunnelStore(defaults: defaults)
    }

    private func assertScrollsOnlyVertically(_ view: some View, inset: CGFloat, _ name: String) throws {
        let window = host(view)
        defer { window.orderOut(nil) }
        let scrollView = try XCTUnwrap(allScrollViews(in: try XCTUnwrap(window.contentView)).first, name)
        let fullWidth = RelayBarPopoverLayout.width
        assertContained(scrollView, in: window, inset: inset, "\(name) as hosted")

        let keeper = LegacyScrollerKeeper(scrollView)
        settle(window)
        XCTAssertEqual(scrollView.scrollerStyle, .legacy, "\(name): the legacy scroller is in force")
        XCTAssertLessThan(scrollView.contentView.bounds.width, fullWidth - 1, "\(name): the viewport narrows")
        assertContained(scrollView, in: window, inset: inset, "\(name) on the legacy scroller")
        keeper.stop()

        scrollView.scrollerStyle = .overlay
        settle(window)
        XCTAssertEqual(scrollView.contentView.bounds.width, fullWidth, accuracy: 0.5, "\(name): the viewport widens")
        assertContained(scrollView, in: window, inset: inset, "\(name) back on the overlay scroller")

        // A one-off reset is undone once the document has followed the narrower viewport.
        scrollView.scrollerStyle = .legacy
        settle(window)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay, "\(name): the overlay scroller is restored")
        XCTAssertEqual(scrollView.contentView.bounds.width, fullWidth, accuracy: 0.5, "\(name): at full width")
        assertContained(scrollView, in: window, inset: inset, "\(name) after a one-off reset")

        window.orderOut(nil)
        settle(window)
        window.orderInOffscreen()
        settle(window)
        XCTAssertEqual(scrollView.scrollerStyle, .overlay, "\(name): shown again on the overlay scroller")
        assertContained(scrollView, in: window, inset: inset, "\(name) shown again")
    }

    /// The document is exactly as wide as the clip view, nothing moves it sideways, and every
    /// AppKit-backed control sits between the balanced insets.
    private func assertContained(
        _ scrollView: NSScrollView, in window: NSWindow, inset: CGFloat, _ name: String, line: UInt = #line
    ) {
        let clip = scrollView.contentView
        XCTAssertEqual(scrollView.frame.width, RelayBarPopoverLayout.width, accuracy: 0.5,
                       "\(name): the scroll view fills the popover", line: line)
        XCTAssertFalse(scrollView.hasHorizontalScroller, "\(name): no horizontal scroller", line: line)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none, "\(name): no horizontal elasticity", line: line)
        guard let document = scrollView.documentView else { return XCTFail("\(name): no document", line: line) }
        XCTAssertEqual(document.frame.width, clip.bounds.width, accuracy: 0.5,
                       "\(name): the document is exactly as wide as the clip view", line: line)
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.5, "\(name): at the leading edge", line: line)

        let top = clip.bounds.minY
        scrollView.scrollWheel(with: sidewaysScroll(by: -40, phase: nil))
        for phase: Int64 in [1, 2, 2, 4] {
            scrollView.scrollWheel(with: sidewaysScroll(by: phase == 2 ? -30 : 0, phase: phase))
        }
        settle(window)
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.5,
                       "\(name): a sideways wheel or swipe leaves the clip view at the leading edge", line: line)
        clip.scroll(to: NSPoint(x: 30, y: top))
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.5,
                       "\(name): so does scrolling the clip view sideways directly", line: line)
        clip.scroll(to: NSPoint(x: 0, y: top))

        let controls = allControls(in: document)
        XCTAssertFalse(controls.isEmpty, "\(name): the document has AppKit-backed controls", line: line)
        for control in controls {
            // Measured by the alignment rectangle, which is what layout places and what the control draws within.
            // On macOS 13 to 15 a pop-up button's frame is a few points wider than that on each side.
            let frame = control.convert(control.alignmentRect(forFrame: control.bounds), to: document)
            XCTAssertGreaterThanOrEqual(frame.minX, inset - 0.5,
                                        "\(name): \(type(of: control)) at \(frame) clears the leading inset",
                                        line: line)
            XCTAssertLessThanOrEqual(frame.maxX, clip.bounds.width - inset + 0.5,
                                     "\(name): \(type(of: control)) at \(frame) clears the trailing inset",
                                     line: line)
        }
    }

    /// A mouse wheel tilted sideways when `phase` is nil, otherwise one event of a trackpad swipe.
    private func sidewaysScroll(by delta: Int32, phase: Int64?) -> NSEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0
        )!
        if let phase {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        }
        return NSEvent(cgEvent: event)!
    }

    private func host(_ view: some View) -> QuietWindow {
        let hosting = NSHostingView(rootView: view.frame(
            width: RelayBarPopoverLayout.width, height: RelayBarPopoverLayout.height
        ))
        let window = QuietWindow(size: RelayBarPopoverLayout.size, styleMask: [.titled])
        window.contentView = hosting
        window.orderInOffscreen()
        settle(window)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<8 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        }
    }

    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(allScrollViews(in:))
    }

    private func allControls(in view: NSView) -> [NSControl] {
        ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap(allControls(in:))
    }
}

/// Puts a scroll view back on the legacy scroller whenever its clip view changes size, standing in for
/// whatever resets the scroller behind the overlay override's back and keeps doing so.
@MainActor
private final class LegacyScrollerKeeper: NSObject {
    private let scrollView: NSScrollView

    init(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewFrameDidChange),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )
        scrollView.scrollerStyle = .legacy
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
    }
}

/// Delivers a nested notification while the old horizontal offset is still visible.
@MainActor
private final class ReentrantClipView: NSClipView {
    var observeCorrections = false
    private var correctionDepth = 0
    private(set) var maximumCorrectionDepth = 0

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        guard observeCorrections, newOrigin.x == 0, bounds.minX != 0 else {
            super.setBoundsOrigin(newOrigin)
            return
        }
        correctionDepth += 1
        defer { correctionDepth -= 1 }
        maximumCorrectionDepth = max(maximumCorrectionDepth, correctionDepth)
        if correctionDepth == 1 {
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: self)
        }
        super.setBoundsOrigin(newOrigin)
    }
}
