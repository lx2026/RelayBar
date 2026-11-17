import AppKit
import Composition
import CompositionFixtures
@testable import HouseStyle
import SwiftUI
import XCTest

@MainActor
final class HousePaletteTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    override func tearDown() {
        HousePalette.apply(.paper)
        super.tearDown()
    }

    // MARK: Contrast

    /// Every text token on every surface it is drawn on, in both forms and both appearances.
    func testTextKeepsAtLeastFourAndAHalfToOneOnItsSurfaces() {
        let P = HousePalette.self
        let everywhere = [P.paper, P.panel, P.card, P.stage, P.selected]
        var pairs: [(text: HouseToken, surface: HouseToken, forms: [HouseForm])] = []
        for text in [P.ink, P.muted] {
            for surface in everywhere { pairs.append((text, surface, HouseForm.allCases)) }
        }
        // Status text sits on the popover, the panels and the cards; never on a stage.
        for text in [P.warning, P.failure] {
            for surface in [P.paper, P.panel, P.card] { pairs.append((text, surface, HouseForm.allCases)) }
        }
        // Amber is text only in the paper form; the standard form uses it for marks.
        for surface in [P.paper, P.panel, P.stage, P.selected] { pairs.append((P.amber, surface, [.paper])) }

        for (text, surface, forms) in pairs {
            for form in forms {
                for name in appearances {
                    let ratio = contrast(text, on: surface, form: form, appearance: name)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text.name) on \(surface.name), \(form), \(name.rawValue)")
                }
            }
        }
    }

    /// Text on the fill wherever the apps draw text on it: once (a highlighted row, a hovered or selected control, a
    /// field) over paper, panel and card; laid twice behind a pressed popover button, and at 1.6 times under the
    /// pointer in Frame's details, both over paper. Status text sits on a fill only in a highlighted popover row.
    func testTextKeepsAtLeastFourAndAHalfToOneOnFills() {
        let P = HousePalette.self
        let layers: [(String, (NSColor) -> NSColor)] = [
            ("fill", { $0 }), ("pressed", { $0 }), ("hover x1.6", { $0.withAlphaComponent(min(1, $0.alphaComponent * 1.6)) })
        ]
        for form in HouseForm.allCases {
            for name in appearances {
                let appearance = NSAppearance(named: name)!
                let paper = P.paper.resolved(in: form, appearance: appearance)
                let fill = P.fill.resolved(in: form, appearance: appearance)
                for surface in [P.paper, P.panel, P.card] {
                    let base = over(surface.resolved(in: form, appearance: appearance), paper)
                    for (label, adjust) in layers where label == "fill" || surface === P.paper {
                        var ground = over(adjust(fill), base)
                        if label == "pressed" { ground = over(fill, ground) }
                        var texts = [P.ink, P.muted]
                        if surface === P.paper, label == "fill" { texts += [P.warning, P.failure] }
                        for text in texts {
                            let ratio = ratio(over(text.resolved(in: form, appearance: appearance), ground), ground)
                            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text.name) on \(label) over \(surface.name), \(form), \(name.rawValue)")
                        }
                    }
                }
            }
        }
    }

    /// The text on a prominent button, and paper-coloured text on an ink badge.
    func testInvertedTextKeepsItsContrast() {
        for form in HouseForm.allCases {
            for name in appearances {
                let appearance = NSAppearance(named: name)!
                let paper = HousePalette.paper.resolved(in: form, appearance: appearance)
                let button = over(HousePalette.button.resolved(in: form, appearance: appearance), paper)
                let buttonText = over(HousePalette.buttonText.resolved(in: form, appearance: appearance), button)
                XCTAssertGreaterThanOrEqual(ratio(buttonText, button), 4.5, "button text, \(form), \(name.rawValue)")
                let ink = over(HousePalette.ink.resolved(in: form, appearance: appearance), paper)
                XCTAssertGreaterThanOrEqual(ratio(paper, ink), 4.5, "paper on ink, \(form), \(name.rawValue)")
            }
        }
    }

    // MARK: Values

    func testPaperFormKeepsFramesValuesAndTheStandardFormFollowsMacOS() {
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        XCTAssertEqual(HousePalette.paper.css(in: .paper, dark: false), "#f8f8f6")
        XCTAssertEqual(HousePalette.paper.css(in: .paper, dark: true), "#242526")
        XCTAssertEqual(HousePalette.ink.css(in: .paper, dark: false), "#252823")
        XCTAssertEqual(HousePalette.line.css(in: .paper, dark: false), "rgba(37,40,35,0.12)")
        XCTAssertEqual(HousePalette.running.css(in: .paper, dark: true), "#32d158")
        for (token, system) in [(HousePalette.paper, NSColor.windowBackgroundColor), (HousePalette.panel, .underPageBackgroundColor),
                                (HousePalette.ink, .labelColor), (HousePalette.line, .separatorColor),
                                (HousePalette.running, .systemGreen)] {
            for appearance in [light, dark] {
                XCTAssertEqual(components(token.resolved(in: .standard, appearance: appearance)),
                               components(resolve(system, appearance)), token.name)
            }
        }
        // A standard card is the control background in light, and lighter than the panel behind it in dark.
        XCTAssertEqual(components(HousePalette.card.resolved(in: .standard, appearance: light)),
                       components(resolve(.controlBackgroundColor, light)))
        let darkCard = HousePalette.card.resolved(in: .standard, appearance: dark)
        let darkPanel = HousePalette.panel.resolved(in: .standard, appearance: dark)
        XCTAssertGreaterThan(darkCard.redComponent, darkPanel.redComponent)
        XCTAssertEqual(darkCard.alphaComponent, 1)
        // Standard status text is macOS's orange and red, darker in light appearance and the red lighter in dark.
        func luminance(_ token: HouseToken, _ appearance: NSAppearance) -> Double {
            let c = token.resolved(in: .standard, appearance: appearance)
            return Double(c.redComponent + c.greenComponent + c.blueComponent)
        }
        func luminance(_ color: NSColor, _ appearance: NSAppearance) -> Double {
            let c = resolve(color, appearance)
            return Double(c.redComponent + c.greenComponent + c.blueComponent)
        }
        XCTAssertLessThan(luminance(HousePalette.warning, light), luminance(.systemOrange, light))
        XCTAssertLessThan(luminance(HousePalette.failure, light), luminance(.systemRed, light))
        XCTAssertGreaterThan(luminance(HousePalette.failure, dark), luminance(.systemRed, dark))
        XCTAssertEqual(HousePalette.warning.css(in: .paper, dark: false), "#a34e00")
        XCTAssertEqual(HousePalette.failure.css(in: .paper, dark: true), "#ff736b")
    }

    // MARK: Switching

    func testApplyingAFormChangesWhatTheTokensDrawAndTellsWindowsToRedraw() {
        HousePalette.apply(.paper)
        let light = NSAppearance(named: .aqua)!
        let posted = expectation(forNotification: HousePalette.didChangeNotification, object: nil)
        XCTAssertEqual(components(resolve(HousePalette.paper.nsColor, light)), components(HousePalette.paper.resolved(in: .paper, appearance: light)))

        XCTAssertTrue(HousePalette.apply(.standard))
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(HousePalette.form, .standard)
        XCTAssertEqual(components(resolve(HousePalette.paper.nsColor, light)), components(resolve(.windowBackgroundColor, light)))
        XCTAssertFalse(HousePalette.apply(.standard), "the same form again changes nothing")

        XCTAssertTrue(HousePalette.apply(.paper))
        XCTAssertEqual(components(resolve(HousePalette.paper.nsColor, light)), components(HousePalette.paper.resolved(in: .paper, appearance: light)))
    }

    /// An open window redraws at once: an AppKit view is marked for display, and a SwiftUI view that reads a token
    /// is drawn again in the new form without being made again, through Observation from macOS 14.
    func testAnOpenWindowRedrawsInTheNewFormKeepingItsState() throws {
        try checkRedraw { AnyView(Swatches(counter: $0)) }
    }

    /// The macOS 13 path, taken here with Observation switched off: a view with a `HouseTracking` property is drawn
    /// again in place, keeping its state, including colours read inside a geometry reader and a button style's view.
    func testWithoutObservationATrackedViewRedrawsInPlace() throws {
        HouseFormTracking.usesObservation = false
        defer { HouseFormTracking.usesObservation = true }
        try checkRedraw { AnyView(TrackedSwatches(counter: $0)) }
    }

    private func checkRedraw(_ make: (SwatchState) -> AnyView) throws {
        HousePalette.apply(.paper)
        let size = NSSize(width: 120, height: 60)
        let model = SwatchState()
        let host = NSHostingView(rootView: make(model))
        host.frame = NSRect(origin: .zero, size: size)
        let window = QuietWindow(size: size)
        window.appearance = NSAppearance(named: .darkAqua)
        let drawn = Drawn(frame: NSRect(origin: .zero, size: size))
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(drawn)
        container.addSubview(host)
        window.contentView = container
        window.orderInOffscreen()
        defer { window.orderOut(nil); window.contentView = nil }
        settle()
        model.taps = 3
        settle()
        let dark = NSAppearance(named: .darkAqua)!
        let appeared = model.appearances
        XCTAssertGreaterThan(appeared, 0)

        XCTAssertEqual(pixel(host, x: 20), rendered(HousePalette.paper, .paper, dark))
        XCTAssertEqual(pixel(host, x: 80), rendered(HousePalette.card, .paper, dark))
        settle()
        let draws = drawn.draws

        HousePalette.apply(.standard)
        settle()
        XCTAssertGreaterThan(drawn.draws, draws, "an AppKit view draws again by itself")
        XCTAssertNotEqual(rendered(HousePalette.paper, .paper, dark), rendered(HousePalette.paper, .standard, dark))
        XCTAssertEqual(pixel(host, x: 20), rendered(HousePalette.paper, .standard, dark), "inside a geometry reader")
        XCTAssertEqual(pixel(host, x: 80), rendered(HousePalette.card, .standard, dark), "a button style redraws too")
        XCTAssertEqual(pixel(drawn, x: 20), rendered(HousePalette.stage, .standard, dark))
        XCTAssertEqual(model.appearances, appeared, "the view was not made again")
        XCTAssertEqual(model.taps, 3)
    }

    // MARK: Plugin

    func testPaperAppearanceIsOnByDefaultAndStoredLikeAnyPlugin() throws {
        let plugin = PaperAppearance.plugin
        XCTAssertEqual(plugin.title, "Paper Appearance")
        XCTAssertEqual(plugin.summary,
                       "Uses the warm paper colours of RelayBar and Frame in this app. Turn it off for standard macOS colours.")
        XCTAssertTrue(plugin.isOnByDefault)
        XCTAssertNotNil(NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: nil))
        var choices = PluginChoices()
        XCTAssertEqual(PaperAppearance.form(choices), .paper)
        choices.set(plugin, enabled: false)
        XCTAssertEqual(PaperAppearance.form(choices), .standard)
        let stored = try JSONEncoder().encode(choices)
        XCTAssertEqual(String(decoding: stored, as: UTF8.self), #"{"paper":false}"#)
        XCTAssertEqual(PaperAppearance.form(try JSONDecoder().decode(PluginChoices.self, from: stored)), .standard)
    }

    // MARK: Helpers

    private func contrast(_ text: HouseToken, on surface: HouseToken, form: HouseForm, appearance name: NSAppearance.Name) -> Double {
        let appearance = NSAppearance(named: name)!
        let ground = over(surface.resolved(in: form, appearance: appearance), HousePalette.paper.resolved(in: form, appearance: appearance))
        return ratio(over(text.resolved(in: form, appearance: appearance), ground), ground)
    }

    private func resolve(_ color: NSColor, _ appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
        return result
    }

    /// `top` composited over an opaque `bottom`.
    private func over(_ top: NSColor, _ bottom: NSColor) -> NSColor {
        let a = top.alphaComponent
        func mix(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * a + b * (1 - a) }
        return NSColor(srgbRed: mix(top.redComponent, bottom.redComponent), green: mix(top.greenComponent, bottom.greenComponent),
                       blue: mix(top.blueComponent, bottom.blueComponent), alpha: 1)
    }

    private func ratio(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func components(_ color: NSColor) -> [Int] {
        [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    /// The pixel a plain AppKit fill of the token draws, read back the same way as the view under test.
    private func rendered(_ token: HouseToken, _ form: HouseForm, _ appearance: NSAppearance) -> [Int] {
        let view = Filled(frame: NSRect(x: 0, y: 0, width: 40, height: 20), color: token.nsColor(in: form))
        let window = QuietWindow(size: view.frame.size)
        window.appearance = appearance
        window.contentView = view
        defer { window.contentView = nil }
        return pixel(view, x: 10)
    }

    private func pixel(_ view: NSView, x: Int) -> [Int] {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let color = rep.colorAt(x: x * Int(rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1), y: 10)!
        return Array(components(color.usingColorSpace(.sRGB)!).prefix(3))
    }

    private func settle() {
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
}

@MainActor
private final class SwatchState: ObservableObject {
    @Published var taps = 0
    var appearances = 0
}

/// Paper on the left, read inside a geometry reader, and a card-filled button on the right. Its `onAppear` counts
/// how often it is made.
private struct Swatches: View {
    @ObservedObject var counter: SwatchState

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { _ in Rectangle().fill(HouseColor.paper) }.frame(width: 60)
            Button("") { counter.taps += 1 }.buttonStyle(CardStyle()).frame(width: 60)
        }
        .frame(maxHeight: .infinity)
        .onAppear { counter.appearances += 1 }
    }
}

private struct CardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rectangle().fill(HouseColor.card).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The same, written for macOS 13: every view that reads a token declares `HouseTracking`.
private struct TrackedSwatches: View {
    @ObservedObject var counter: SwatchState
    @HouseTracking private var house

    var body: some View {
        HStack(spacing: 0) {
            // Like the popover's scroll container, the reader's content is built by a closure that captures the view.
            GeometryReader { _ in paperSwatch }.frame(width: 60)
            Button("") { counter.taps += 1 }.buttonStyle(TrackedCardStyle()).frame(width: 60)
        }
        .frame(maxHeight: .infinity)
        .onAppear { counter.appearances += 1 }
    }
}

private extension TrackedSwatches {
    var paperSwatch: some View { Rectangle().fill(HouseColor.paper) }
}

private struct TrackedCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face() }

    private struct Face: View {
        @HouseTracking private var house

        var body: some View { Rectangle().fill(HouseColor.card).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

private final class Drawn: NSView {
    private(set) var draws = 0

    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        HousePalette.stage.nsColor.setFill()
        bounds.fill()
    }
}

private final class Filled: NSView {
    let color: NSColor

    init(frame: NSRect, color: NSColor) {
        self.color = color
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
