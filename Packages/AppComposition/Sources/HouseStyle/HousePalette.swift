#if os(macOS)
import AppKit
typealias PaletteColor = NSColor
typealias PaletteAppearance = NSAppearance
typealias StandardColors = NSColor
#else
import UIKit
typealias PaletteColor = UIColor
typealias PaletteAppearance = UITraitCollection
#endif
import os
import SwiftUI

/// The two forms of the house palette: the warm paper tones RelayBar and Frame share, or the standard macOS colours.
public enum HouseForm: String, CaseIterable, Sendable {
    case paper
    case standard
}

/// One role in the house palette. Its colour is picked when it is drawn, from the active form and the appearance of
/// whatever draws it, so a view keeps the same colour object whatever the form.
public final class HouseToken: @unchecked Sendable {
    public let name: String
    private let fixed: [HouseForm: PaletteColor]
    let swiftUI: [HouseForm: Color]

    #if os(macOS)
    public let nsColor: NSColor
    #else
    public let uiColor: UIColor
    #endif

    init(_ name: String, light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1,
         standard: @escaping @Sendable (PaletteAppearance) -> PaletteColor) {
        self.name = name
        let lightColor = Self.srgb(light, alpha: lightAlpha)
        let darkColor = Self.srgb(dark, alpha: darkAlpha)
        func resolve(_ form: HouseForm, _ appearance: PaletteAppearance) -> PaletteColor {
            if form == .standard { return standard(appearance) }
            return Self.isDark(appearance) ? darkColor : lightColor
        }
        #if os(macOS)
        fixed = Dictionary(uniqueKeysWithValues: HouseForm.allCases.map { form in
            (form, NSColor(name: "house.\(name).\(form.rawValue)") { resolve(form, $0) })
        })
        swiftUI = fixed.mapValues { Color(nsColor: $0) }
        nsColor = NSColor(name: "house.\(name)") { resolve(HousePalette.form, $0) }
        #else
        fixed = Dictionary(uniqueKeysWithValues: HouseForm.allCases.map { form in
            (form, UIColor { resolve(form, $0).resolvedColor(with: $0) })
        })
        swiftUI = fixed.mapValues { Color(uiColor: $0) }
        uiColor = UIColor { resolve(HousePalette.form, $0).resolvedColor(with: $0) }
        #endif
    }

    #if os(macOS)
    public func nsColor(in form: HouseForm) -> NSColor {
        fixed[form] ?? nsColor
    }

    public func resolved(in form: HouseForm, appearance: NSAppearance) -> NSColor {
        Self.components(of: nsColor(in: form), in: appearance)
    }
    #else
    public func uiColor(in form: HouseForm) -> UIColor {
        fixed[form] ?? uiColor
    }

    public func resolved(in form: HouseForm, appearance: UITraitCollection) -> UIColor {
        Self.components(of: uiColor(in: form), in: appearance)
    }
    #endif

    /// A CSS colour for a page drawn in one form and appearance: `#rrggbb`, or `rgba()` when it is translucent.
    /// Read on the main actor, because the standard form resolves system colours.
    @MainActor public func css(in form: HouseForm, dark: Bool) -> String {
        #if os(macOS)
        let color = resolved(in: form, appearance: NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing())
        #else
        let color = resolved(in: form, appearance: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        #endif
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        if color.alphaComponent >= 1 {
            return "#" + channels.map { String(format: "%02x", $0) }.joined()
        }
        return "rgba(\(channels.map(String.init).joined(separator: ",")),\(String(format: "%.3g", color.alphaComponent)))"
    }

    /// A system colour for small text: moved towards black in light appearance and towards white in dark by at least
    /// the given amount, then further in small steps until it keeps 4.5:1 on every one of `grounds`, plain and under
    /// `fill`. The system's window colours differ between versions of macOS, so a fixed amount is not enough.
    static func readable(_ color: PaletteColor, in appearance: PaletteAppearance, darken: CGFloat, lighten: CGFloat,
                         on grounds: [PaletteColor], under fill: PaletteColor) -> PaletteColor {
        let base = components(of: color, in: appearance)
        let dark = isDark(appearance)
        let target: CGFloat = dark ? 1 : 0
        let surfaces = grounds + grounds.map { over(fill, $0) }
        var amount = dark ? lighten : darken
        while true {
            func move(_ value: CGFloat) -> CGFloat { value + (target - value) * amount }
            let moved = PaletteColor(srgbRed: move(base.redComponent), green: move(base.greenComponent),
                                blue: move(base.blueComponent), alpha: base.alphaComponent)
            if amount >= 1 || surfaces.allSatisfy({ contrast(over(moved, $0), $0) >= 4.6 }) { return moved }
            amount = min(1, amount + 0.05)
        }
    }

    /// `top` drawn over an opaque `bottom`, both in sRGB.
    static func over(_ top: PaletteColor, _ bottom: PaletteColor) -> PaletteColor {
        let a = top.alphaComponent
        func mix(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * a + b * (1 - a) }
        return PaletteColor(srgbRed: mix(top.redComponent, bottom.redComponent), green: mix(top.greenComponent, bottom.greenComponent),
                       blue: mix(top.blueComponent, bottom.blueComponent), alpha: 1)
    }

    /// The WCAG contrast ratio of two opaque sRGB colours.
    static func contrast(_ a: PaletteColor, _ b: PaletteColor) -> CGFloat {
        func luminance(_ color: PaletteColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func isDark(_ appearance: PaletteAppearance) -> Bool {
        #if os(macOS)
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        appearance.userInterfaceStyle == .dark
        #endif
    }

    static func components(of color: PaletteColor, in appearance: PaletteAppearance) -> PaletteColor {
        #if os(macOS)
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
        #else
        return color.resolvedColor(with: appearance)
        #endif
    }

    static func srgb(_ value: UInt32, alpha: CGFloat) -> PaletteColor {
        PaletteColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

/// The colours RelayBar and Frame draw with, defined once. Each token has Frame's paper values, light and dark, and a
/// standard form made of the matching macOS semantic colours. The system accent colour is not a token.
public enum HousePalette {
    // MARK: Surfaces

    /// The main surface: Frame's reader and grid, RelayBar's popover, the Remote Files content and the Plugins map.
    public static let paper = HouseToken("paper", light: 0xf8f8f6, dark: 0x242526) { _ in StandardColors.windowBackgroundColor }
    /// Sidebars and side panels, and the Settings window behind its boxes.
    public static let panel = HouseToken("panel", light: 0xf0f0ed, dark: 0x292a2b) { standardPanel($0) }
    /// The well behind a picture or a preview.
    public static let stage = HouseToken("stage", light: 0xe4e5e1, dark: 0x17191a) { _ in StandardColors.underPageBackgroundColor }
    /// A raised card: Settings boxes, the profile editor's rule cards, tiles and map nodes. In the standard form it is
    /// the control background in light appearance; in dark, where that matches the window, it is the panel
    /// colour lifted a little towards the label colour, so a box still stands out from the panel behind it.
    public static let card = HouseToken("card", light: 0xffffff, dark: 0x343637) { appearance in
        guard HouseToken.isDark(appearance) else { return StandardColors.controlBackgroundColor }
        let base = standardPanel(appearance)
        let label = HouseToken.components(of: StandardColors.labelColor, in: appearance)
        let lift = 0.06 * label.alphaComponent
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * lift }
        return PaletteColor(srgbRed: mix(base.redComponent, label.redComponent), green: mix(base.greenComponent, label.greenComponent),
                       blue: mix(base.blueComponent, label.blueComponent), alpha: 1)
    }
    /// A selected row or tile that is not the focus.
    public static let selected = HouseToken("selected", light: 0xd4d7cf, dark: 0x3d403b) { _ in
        StandardColors.unemphasizedSelectedContentBackgroundColor
    }

    // MARK: Text and marks

    /// Primary text.
    public static let ink = HouseToken("ink", light: 0x252823, dark: 0xeeefeb) { _ in StandardColors.labelColor }
    /// Secondary text. The standard form sits halfway between the secondary label colour and the label colour,
    /// because the secondary label colour alone falls below 4.5:1 on a light window.
    public static let muted = HouseToken("muted", light: 0x585d54, dark: 0xb5b9b0) { appearance in
        let label = HouseToken.components(of: StandardColors.labelColor, in: appearance)
        let secondary = HouseToken.components(of: StandardColors.secondaryLabelColor, in: appearance)
        func mid(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + b) / 2 }
        return PaletteColor(srgbRed: mid(label.redComponent, secondary.redComponent),
                       green: mid(label.greenComponent, secondary.greenComponent),
                       blue: mid(label.blueComponent, secondary.blueComponent),
                       alpha: mid(label.alphaComponent, secondary.alphaComponent))
    }
    /// Placeholder glyphs and quiet marks; never text.
    public static let faint = HouseToken("faint", light: 0x8b8f86, dark: 0x80847c) { _ in StandardColors.tertiaryLabelColor }
    /// Hairlines between columns, under headers and above footers.
    public static let line = HouseToken("line", light: 0x252823, dark: 0xffffff, lightAlpha: 0.12, darkAlpha: 0.1) { _ in
        StandardColors.separatorColor
    }
    /// The quiet fill behind fields, segmented controls and blocks, and under a pointer; pressed is the fill laid twice.
    /// The standard form is the label colour at 7%, as faint as RelayBar's earlier hover, so status text on a
    /// highlighted row keeps 4.5:1 even on the grey window of macOS 13 to 15.
    public static let fill = HouseToken("fill", light: 0x252823, dark: 0xffffff, lightAlpha: 0.07, darkAlpha: 0.08) { appearance in
        let label = HouseToken.components(of: StandardColors.labelColor, in: appearance)
        return label.withAlphaComponent(label.alphaComponent * 0.07)
    }
    /// Favourites.
    public static let amber = HouseToken("amber", light: 0x805000, dark: 0xf1bd62) { _ in StandardColors.systemOrange }
    /// Destructive actions.
    public static let red = HouseToken("red", light: 0xb8241a, dark: 0xff6b62) { _ in StandardColors.systemRed }
    /// A prominent button's fill, and the text on it.
    public static let button = HouseToken("button", light: 0x30352d, dark: 0xe2e6dc) { _ in StandardColors.labelColor }
    public static let buttonText = HouseToken("buttonText", light: 0xffffff, dark: 0x252823) { _ in StandardColors.windowBackgroundColor }

    // MARK: Status

    /// A running tunnel's dot and a running feature's mark.
    public static let running = HouseToken("running", light: 0x28a745, dark: 0x32d158) { _ in StandardColors.systemGreen }
    /// The arc of a tunnel that waits to retry, and a stuck feature's mark.
    public static let retrying = HouseToken("retrying", light: 0xf08c00, dark: 0xff9f0a) { _ in StandardColors.systemOrange }
    /// Orange status text. In the standard form, macOS's orange darkened in light appearance, where it is too light
    /// for small text, and as much further as this version of macOS needs.
    public static let warning = HouseToken("warning", light: 0xa34e00, dark: 0xffb340) { appearance in
        standardStatus(StandardColors.systemOrange, appearance, darken: 0.45, lighten: 0)
    }
    /// Red status text and the failure mark. The paper dark value is a shade lighter than the popover's earlier red,
    /// which fell just short of 4.5:1 on a card. In the standard form, macOS's red darkened in light appearance and
    /// lightened in dark, and as much further as this version of macOS needs.
    public static let failure = HouseToken("failure", light: 0xc92a1e, dark: 0xff736b) { appearance in
        standardStatus(StandardColors.systemRed, appearance, darken: 0.3, lighten: 0.25)
    }

    /// The standard panel. On current macOS the under-page colour is a quiet variation of the window and is used as
    /// it is. On macOS 13 to 15 it is a mid grey in light appearance, too dark for a sidebar and for the text on it,
    /// so there the panel is the window colour.
    private static func standardPanel(_ appearance: PaletteAppearance) -> PaletteColor {
        let window = HouseToken.components(of: StandardColors.windowBackgroundColor, in: appearance)
        let underPage = HouseToken.components(of: StandardColors.underPageBackgroundColor, in: appearance)
        return HouseToken.contrast(window, underPage) <= 1.25 ? underPage : window
    }

    /// Standard status text, readable on the standard paper, panel and card, plain and under the fill.
    private static func standardStatus(_ color: PaletteColor, _ appearance: PaletteAppearance, darken: CGFloat, lighten: CGFloat) -> PaletteColor {
        let grounds = [HouseToken.components(of: StandardColors.windowBackgroundColor, in: appearance), standardPanel(appearance),
                       card.resolved(in: .standard, appearance: appearance)]
        return HouseToken.readable(color, in: appearance, darken: darken, lighten: lighten, on: grounds,
                                   under: fill.resolved(in: .standard, appearance: appearance))
    }

    /// Every token, for tests and listings.
    public static let all: [HouseToken] = [
        paper, panel, stage, card, selected, ink, muted, faint, line, fill, amber, red, button, buttonText,
        running, retrying, warning, failure
    ]

    // MARK: Form

    private static let state = OSAllocatedUnfairLock(initialState: HouseForm.paper)

    /// The form every token draws in. Paper until an app applies its stored choice.
    public static var form: HouseForm { state.withLock { $0 } }

    /// Posted on the main thread after the form changes, once every open window has been marked for redrawing.
    public static let didChangeNotification = Notification.Name("HousePaletteDidChange")

    /// Switches every token to `form`. Open windows redraw at once: SwiftUI views that read a token update, every
    /// AppKit view is marked for display, and `didChangeNotification` reaches anything that keeps its own copy,
    /// such as a web page's style sheet. Returns whether anything changed.
    @MainActor @discardableResult
    public static func apply(_ form: HouseForm) -> Bool {
        let changed = state.withLock { current in
            defer { current = form }
            return current != form
        }
        guard changed else { return false }
        HouseFormTracking.changed(to: form)
        #if os(macOS)
        if let app = NSApp {
            for window in app.windows {
                if let root = window.contentView?.superview ?? window.contentView { markForDisplay(root) }
            }
        }
        #else
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { markForDisplay(window) }
        }
        #endif
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        return true
    }

    #if os(macOS)
    @MainActor private static func markForDisplay(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews { markForDisplay(subview) }
    }
    #else
    @MainActor private static func markForDisplay(_ view: UIView) {
        view.setNeedsDisplay()
        for subview in view.subviews { markForDisplay(subview) }
    }
    #endif
}
