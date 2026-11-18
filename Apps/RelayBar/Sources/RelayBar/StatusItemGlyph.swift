import AppKit

/// The menu-bar glyph: the Route mark, drawn as a template image whose
/// strength and trailing exclamation mark follow the tunnels' phases.
enum StatusItemGlyph {
    enum State: Equatable, Sendable {
        /// Nothing starting, retrying, running or failed: the mark at 45% alpha.
        case idle
        /// At least one tunnel starting, retrying or running.
        case active
        /// At least one tunnel failed, whatever the others are doing.
        case failed
    }

    struct Summary: Equatable {
        let activeCount: Int
        let failedCount: Int

        init<Phases: Sequence>(phases: Phases) where Phases.Element == TunnelPhase {
            var active = 0, failed = 0
            for phase in phases {
                if phase.isLifecycleActive { active += 1 }
                if case .failed = phase { failed += 1 }
            }
            activeCount = active
            failedCount = failed
        }

        var state: State {
            if failedCount > 0 { return .failed }
            return activeCount > 0 ? .active : .idle
        }

        var accessibilityLabel: String {
            let active: String
            switch activeCount {
            case 0: active = "no tunnels active"
            case 1: active = "1 tunnel active"
            default: active = "\(activeCount) tunnels active"
            }
            guard failedCount > 0 else { return "RelayBar, \(active)" }
            return "RelayBar, \(active), \(failedCount) failed"
        }
    }

    static let markSize = NSSize(width: 18, height: 18)
    /// The exclamation mark's column and the gap before it.
    static let alertGap: CGFloat = 2
    static let alertWidth: CGFloat = 5
    static let idleAlpha: CGFloat = 0.45

    static func size(for state: State) -> NSSize {
        guard state == .failed else { return markSize }
        return NSSize(width: markSize.width + alertGap + alertWidth, height: markSize.height)
    }

    @MainActor private static var current: (summary: Summary, image: NSImage)?

    /// The status item's image. The menu bar takes the item's accessibility
    /// label from the image's description, not from the SwiftUI label, so the
    /// description carries the counts. The last image is reused while the
    /// counts stay the same.
    @MainActor static func image(for summary: Summary) -> NSImage {
        if let current, current.summary == summary { return current.image }
        let image = makeImage(for: summary.state)
        image.accessibilityDescription = summary.accessibilityLabel
        current = (summary, image)
        return image
    }

    static func makeImage(for state: State) -> NSImage {
        // Flipped, so the coordinates below read like the mark's y-down drawing.
        let image = NSImage(size: size(for: state), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ state: State, in context: CGContext) {
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Overlapping strokes are composited once, then dimmed as a whole.
        if state == .idle { context.setAlpha(idleAlpha) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        let route = CGMutablePath()
        route.move(to: CGPoint(x: 5.3, y: 12.4))
        route.addLine(to: CGPoint(x: 6.8, y: 12.4))
        route.addCurve(
            to: CGPoint(x: 11.2, y: 5.6),
            control1: CGPoint(x: 9.4, y: 12.4),
            control2: CGPoint(x: 8.6, y: 5.6)
        )
        route.addLine(to: CGPoint(x: 12.2, y: 5.6))
        context.addPath(route)
        context.strokePath()

        context.strokeEllipse(in: circle(x: 3.6, y: 12.4, radius: 1.7))
        context.fillEllipse(in: circle(x: 14.2, y: 5.6, radius: 2.2))

        if state == .failed {
            let x = markSize.width + alertGap + alertWidth / 2
            context.move(to: CGPoint(x: x, y: 4.5))
            context.addLine(to: CGPoint(x: x, y: 10.5))
            context.strokePath()
            context.fillEllipse(in: circle(x: x, y: 13.5, radius: 1.25))
        }

        context.endTransparencyLayer()
    }

    private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }
}
