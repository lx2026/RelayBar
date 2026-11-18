import AppKit
import XCTest
@testable import RelayBar

@MainActor
final class StatusItemGlyphTests: XCTestCase {
    private typealias Summary = StatusItemGlyph.Summary

    func testStateFollowsTheTunnelsAndAFailureTakesPrecedence() {
        XCTAssertEqual(Summary(phases: []).state, .idle)
        XCTAssertEqual(Summary(phases: [.stopped, .stopped]).state, .idle)
        XCTAssertEqual(Summary(phases: [.stopped, .starting]).state, .active)
        XCTAssertEqual(
            Summary(phases: [.retrying(attempt: 1, maxAttempts: 10, delay: 5, message: "refused")]).state,
            .active
        )
        XCTAssertEqual(Summary(phases: [.running, .stopped]).state, .active)
        XCTAssertEqual(Summary(phases: [.failed("timed out")]).state, .failed)
        XCTAssertEqual(Summary(phases: [.running, .running, .failed("timed out")]).state, .failed)
    }

    func testAccessibilityLabelNamesTheAppAndTheCounts() {
        XCTAssertEqual(Summary(phases: []).accessibilityLabel, "RelayBar, no tunnels active")
        XCTAssertEqual(Summary(phases: [.running, .stopped]).accessibilityLabel, "RelayBar, 1 tunnel active")
        XCTAssertEqual(
            Summary(phases: [.running, .starting, .retrying(attempt: 2, maxAttempts: 3, delay: 10, message: "")])
                .accessibilityLabel,
            "RelayBar, 3 tunnels active"
        )
        XCTAssertEqual(
            Summary(phases: [.running, .running, .failed("timed out")]).accessibilityLabel,
            "RelayBar, 2 tunnels active, 1 failed"
        )
        XCTAssertEqual(
            Summary(phases: [.failed("a"), .failed("b")]).accessibilityLabel,
            "RelayBar, no tunnels active, 2 failed"
        )
    }

    func testImagesAreTemplatesAtTheMenuBarSizeAndDescribeTheCounts() {
        for phases in [[], [TunnelPhase.running]] {
            let summary = Summary(phases: phases)
            let image = StatusItemGlyph.image(for: summary)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.accessibilityDescription, summary.accessibilityLabel)
        }
        let failed = StatusItemGlyph.image(for: Summary(phases: [.running, .failed("timed out")]))
        XCTAssertEqual(failed.size, NSSize(width: 25, height: 18), "18-point mark, 2-point gap, 5-point column")
        XCTAssertTrue(failed.isTemplate)
        XCTAssertEqual(failed.accessibilityDescription, "RelayBar, 1 tunnel active, 1 failed")

        let running = Summary(phases: [.running, .starting])
        XCTAssertTrue(StatusItemGlyph.image(for: running) === StatusItemGlyph.image(for: running),
                      "Unchanged counts keep the status item's image")
        XCTAssertFalse(StatusItemGlyph.image(for: running) === StatusItemGlyph.image(for: Summary(phases: [.running])))
    }

    /// Samples the drawing with y measured from the top, as the mark is specified.
    func testDrawingIsUprightDimmedWhenIdleAndMarksAFailure() throws {
        let active = try render(.active)
        XCTAssertEqual(active.alpha(x: 14.2, y: 5.6), 1, accuracy: 0.02, "The filled dot is at the top right")
        XCTAssertEqual(active.alpha(x: 14.2, y: 12.4), 0, accuracy: 0.02, "Nothing at the dot's mirror image")
        XCTAssertEqual(active.alpha(x: 3.6, y: 12.4), 0, accuracy: 0.02, "The ring is hollow")
        XCTAssertEqual(active.alpha(x: 3.6 - 1.7, y: 12.4), 1, accuracy: 0.05, "The ring's stroke")
        XCTAssertEqual(active.alpha(x: 9, y: 9), 1, accuracy: 0.1, "The route crosses the middle")

        let idle = try render(.idle)
        XCTAssertEqual(idle.alpha(x: 14.2, y: 5.6), 0.45, accuracy: 0.03)
        XCTAssertEqual(idle.alpha(x: 5.3, y: 12.4), 0.45, accuracy: 0.03, "Overlapping strokes are dimmed once")

        let failed = try render(.failed)
        XCTAssertEqual(failed.alpha(x: 22.5, y: 7.5), 1, accuracy: 0.05, "The exclamation mark's bar")
        XCTAssertEqual(failed.alpha(x: 22.5, y: 13.5), 1, accuracy: 0.05, "The exclamation mark's dot")
        XCTAssertEqual(failed.alpha(x: 22.5, y: 12), 0, accuracy: 0.05, "A gap between bar and dot")
        XCTAssertEqual(failed.alpha(x: 19, y: 9), 0, accuracy: 0.02, "A gap before the exclamation mark")
    }

    private struct Rendering {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        func alpha(x: CGFloat, y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? -1
        }
    }

    private func render(_ state: StatusItemGlyph.State, scale: CGFloat = 10) throws -> Rendering {
        let image = StatusItemGlyph.makeImage(for: state)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // A bitmap's rows run from the top, like the specification's y.
        return Rendering(rep: rep, scale: scale)
    }
}
