import AppKit
import CompositionFixtures
import HouseStyle
import SwiftUI
import XCTest
@testable import RelayBar

@MainActor
final class PopoverPresentationTests: XCTestCase {
    private let retrying = TunnelPhase.retrying(attempt: 2, maxAttempts: 10, delay: 3.2, message: "Connection refused")

    func testHeaderSummaryCountsActiveTunnelsAndIssues() {
        let empty = PopoverHeaderSummary(phases: [])
        XCTAssertNil(empty.activity)
        XCTAssertNil(empty.issues)
        XCTAssertEqual(empty.accessibilityLabel, "RelayBar")

        let stopped = PopoverHeaderSummary(phases: [.stopped, .stopped])
        XCTAssertEqual(stopped.activity, "All stopped")
        XCTAssertNil(stopped.issues)
        XCTAssertEqual(stopped.accessibilityLabel, "RelayBar, all stopped")

        // Starting, retrying and running are active; a failure is an issue, not activity.
        let mixed = PopoverHeaderSummary(phases: [.running, .starting, retrying, .stopped, .failed("Timed out")])
        XCTAssertEqual(mixed.activity, "3 active")
        XCTAssertEqual(mixed.issues, "1 issue")
        XCTAssertEqual(mixed.accessibilityLabel, "RelayBar, 3 active, 1 issue")

        let failed = PopoverHeaderSummary(phases: [.failed("A"), .failed("B"), .stopped])
        XCTAssertEqual(failed.activity, "All stopped")
        XCTAssertEqual(failed.issues, "2 issues")
        XCTAssertEqual(failed.accessibilityLabel, "RelayBar, all stopped, 2 issues")

        XCTAssertEqual(PopoverHeaderSummary(phases: [.running]).activity, "1 active")
    }

    func testRowDetailShowsHostOrStatusWithItsFullWordingInTheTooltip() {
        let host = "preview-1.example.com"
        let label = ServiceLabel(name: "ComfyUI", isResponding: true)

        for phase in [TunnelPhase.stopped, .running] {
            let plain = TunnelRowDetail(phase: phase, host: host, serviceLabel: nil)
            XCTAssertEqual(plain.text, host)
            XCTAssertEqual(plain.help, host)
            XCTAssertEqual(plain.tone, .secondary)
            let labelled = TunnelRowDetail(phase: phase, host: host, serviceLabel: label)
            XCTAssertEqual(labelled.text, "preview-1.example.com · ComfyUI")
        }
        XCTAssertEqual(
            TunnelRowDetail(phase: .running, host: host, serviceLabel: ServiceLabel(name: nil, isResponding: false)).text,
            "preview-1.example.com · no response"
        )

        let starting = TunnelRowDetail(phase: .starting, host: host, serviceLabel: label)
        XCTAssertEqual(starting.text, "Connecting…")
        XCTAssertEqual(starting.tone, .secondary)

        let retry = TunnelRowDetail(phase: retrying, host: host, serviceLabel: nil)
        XCTAssertEqual(retry.text, "Retrying in 4s · attempt 2 of 10")
        XCTAssertEqual(retry.help, "Retrying in 4s · Connection refused")
        XCTAssertEqual(retry.spokenText, "Retrying in 4s · attempt 2 of 10 · Connection refused")
        XCTAssertEqual(retry.tone, .warning)
        XCTAssertEqual(
            TunnelRowDetail(
                phase: .retrying(attempt: 1, maxAttempts: 3, delay: 0, message: "x"), host: host, serviceLabel: nil
            ).text,
            "Retrying in 1s · attempt 1 of 3"
        )

        let message = "ssh: connect to host preview-1.example.com port 22: Operation timed out"
        let failure = TunnelRowDetail(phase: .failed(message), host: host, serviceLabel: label)
        XCTAssertEqual(failure.text, message)
        XCTAssertEqual(failure.help, message)
        XCTAssertEqual(failure.tone, .failure)
    }

    func testGroupHeaderOffersStopAllWhileAnyMemberIsActiveAndStartAllOtherwise() {
        func action(_ phases: [TunnelPhase]) -> (TunnelGroupPrimaryAction, Bool) {
            let availability = TunnelGroupActionAvailability(phases: phases)
            return (availability.primaryAction, availability.isPrimaryActionAvailable)
        }
        XCTAssertTrue(action([.stopped, .failed("x")]) == (.startAll, true))
        XCTAssertTrue(action([.running, .stopped]) == (.stopAll, true))
        XCTAssertTrue(action([.starting]) == (.stopAll, true))
        XCTAssertTrue(action([retrying, .failed("x")]) == (.stopAll, true))
        XCTAssertTrue(action([]) == (.startAll, false))

        XCTAssertEqual(TunnelGroupPrimaryAction.startAll.title, "Start All")
        XCTAssertEqual(TunnelGroupPrimaryAction.stopAll.title, "Stop All")
        XCTAssertEqual(TunnelGroupPrimaryAction.startAll.label(forGroup: "Work"), "Start all tunnels in Work")
        XCTAssertEqual(TunnelGroupPrimaryAction.stopAll.label(forGroup: "Work"), "Stop all tunnels in Work")
    }

    /// The popover's status and secondary text on its paper, in both forms and both appearances.
    func testStatusTextColoursKeepContrastOnThePopoverBackground() throws {
        for form in HouseForm.allCases {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let backdrop = HousePalette.paper.resolved(in: form, appearance: appearance)
                for token in [HousePalette.warning, HousePalette.failure, HousePalette.muted, HousePalette.ink] {
                    let colour = token.resolved(in: form, appearance: appearance)
                    let ratio = contrast(over(colour, backdrop), backdrop)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(token.name) text, \(form), \(name.rawValue): \(ratio)")
                }
            }
        }
    }

    /// `top` laid over an opaque `bottom`.
    private func over(_ top: NSColor, _ bottom: NSColor) -> NSColor {
        let alpha = top.alphaComponent
        func mix(_ upper: CGFloat, _ lower: CGFloat) -> CGFloat { upper * alpha + lower * (1 - alpha) }
        return NSColor(srgbRed: mix(top.redComponent, bottom.redComponent), green: mix(top.greenComponent, bottom.greenComponent),
                       blue: mix(top.blueComponent, bottom.blueComponent), alpha: 1)
    }

    /// With "Show scroll bars" set to Always, or a mouse connected, AppKit puts scroll views on the legacy
    /// scroller; the list and the editor keep the overlay scroller, so neither viewport is narrowed and no
    /// document is wider than its viewport. `NSScroller.preferredScrollerStyle` is read once per process,
    /// so a default set by a test does not reliably reach it; the legacy style is put on the scroll views
    /// directly instead: before they are first shown, and as AppKit does when the preferred style changes.
    func testPopoverScrollViewsUseOverlayScrollersWhenScrollBarsAreAlwaysShown() throws {
        let suite = "RelayBarPopoverScrolling.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = TunnelStore(defaults: defaults)
        for index in 0..<14 {
            store.add(Tunnel(
                name: "Tunnel \(index) with a long name that would run under a scroller",
                localPort: 8_000 + index, destinationHost: "localhost", destinationPort: 3_000 + index,
                sshHost: "host-\(index).example.com", groupTag: index.isMultiple(of: 2) ? "Work" : nil
            ))
        }
        let editTunnel = try XCTUnwrap(store.tunnels.first)

        let screens: [(String, AnyView)] = [
            ("list", AnyView(RelayBarRootView().environmentObject(store))),
            ("editor", AnyView(TunnelEditorView(tunnel: editTunnel, availableGroups: ["Work"], onCancel: {}, onSave: { _ in })))
        ]
        for (name, view) in screens {
            let window = host(view) { content in
                let scrollViews = self.allScrollViews(in: content)
                XCTAssertEqual(scrollViews.count, 1, "\(name) before it is shown")
                for scrollView in scrollViews {
                    scrollView.scrollerStyle = .legacy
                }
            }
            defer { window.orderOut(nil) }
            let scrollViews = allScrollViews(in: try XCTUnwrap(window.contentView))
            XCTAssertEqual(scrollViews.count, 1, name)
            for scrollView in scrollViews {
                assertOverlay(scrollView, "\(name) shown on the legacy scroller")

                // AppKit moves every scroll view to the new preferred style in its own observer, which may
                // run before or after the popover's.
                let styleChange = NSScroller.preferredScrollerStyleDidChangeNotification
                scrollView.scrollerStyle = .legacy
                NotificationCenter.default.post(name: styleChange, object: nil)
                settle(window)
                assertOverlay(scrollView, "\(name) after a style change")

                NotificationCenter.default.post(name: styleChange, object: nil)
                scrollView.scrollerStyle = .legacy
                settle(window)
                assertOverlay(scrollView, "\(name) after a style change applied late")
            }
        }
    }

    func testSwitchReturnsToTheTunnelStateWhenARequestChangesNothing() throws {
        final class Counter { var value = 0 }
        let requests = Counter()
        let window = host(AnyView(TunnelSwitch(name: "Photos", isActive: false, onToggle: { requests.value += 1 })))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        guard let control = allSwitches(in: content).first else {
            throw XCTSkip("This macOS does not back the SwiftUI switch with NSSwitch.")
        }
        XCTAssertEqual(control.state, .off)

        control.performClick(nil)
        settle(window)

        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(allSwitches(in: content).first?.state, .off,
                       "the tunnel did not start, so the switch goes back")
    }

    // MARK: Helpers

    private func allSwitches(in view: NSView) -> [NSSwitch] {
        (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap(allSwitches(in:))
    }

    private func assertOverlay(_ scrollView: NSScrollView, _ name: String, line: UInt = #line) {
        XCTAssertEqual(scrollView.scrollerStyle, .overlay, name, line: line)
        XCTAssertEqual(scrollView.contentView.bounds.width, scrollView.bounds.width, accuracy: 0.5,
                       "\(name): the viewport is the full width", line: line)
        let documentWidth = scrollView.documentView?.bounds.width ?? .infinity
        XCTAssertLessThanOrEqual(documentWidth, scrollView.contentView.bounds.width + 0.5,
                                 "\(name): the document fits the viewport", line: line)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.5, name, line: line)
    }

    /// `beforeShowing` receives the hosting view once it has been laid out, before it is put in a window.
    private func host(_ view: AnyView, beforeShowing: (NSView) -> Void = { _ in }) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(
            width: RelayBarPopoverLayout.width, height: RelayBarPopoverLayout.height
        ))
        hosting.frame = NSRect(origin: .zero, size: RelayBarPopoverLayout.size)
        hosting.layoutSubtreeIfNeeded()
        beforeShowing(hosting)
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

    private func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ colour: NSColor) -> CGFloat {
            func channel(_ value: CGFloat) -> CGFloat {
                value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(colour.redComponent) + 0.7152 * channel(colour.greenComponent)
                + 0.0722 * channel(colour.blueComponent)
        }
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
