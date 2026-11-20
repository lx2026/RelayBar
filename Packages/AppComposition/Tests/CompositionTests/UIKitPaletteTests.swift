#if os(iOS)
import HouseStyle
import UIKit
import XCTest

@MainActor
final class UIKitPaletteTests: XCTestCase {
    func testStandardColoursMatchMacLightAndDark() {
        let expected = [
            ("paper", "#ffffff", "#1e1e1e"), ("panel", "#f6f6f6", "#282828"),
            ("stage", "#f6f6f6", "#282828"), ("card", "#ffffff", "#333333"),
            ("selected", "#dcdcdc", "#464646"), ("ink", "rgba(0,0,0,0.847)", "rgba(255,255,255,0.847)"),
            ("muted", "rgba(0,0,0,0.673)", "rgba(255,255,255,0.698)"),
            ("faint", "rgba(0,0,0,0.259)", "rgba(255,255,255,0.247)"),
            ("line", "rgba(0,0,0,0.1)", "rgba(255,255,255,0.12)"),
            ("fill", "rgba(0,0,0,0.0593)", "rgba(255,255,255,0.0593)"),
            ("amber", "#ff8d28", "#ff9230"), ("red", "#ff383c", "#ff4245"),
            ("button", "rgba(0,0,0,0.847)", "rgba(255,255,255,0.847)"),
            ("buttonText", "#ffffff", "#1e1e1e"), ("running", "#34c759", "#30d158"),
            ("retrying", "#ff8d28", "#ff9230"), ("warning", "#8c4e16", "#ff9230"),
            ("failure", "#b3272a", "#ff8e8f")
        ]
        XCTAssertEqual(HousePalette.all.map(\.name), expected.map { $0.0 })
        for (token, values) in zip(HousePalette.all, expected) {
            XCTAssertEqual(token.css(in: .standard, dark: false), values.1, token.name)
            XCTAssertEqual(token.css(in: .standard, dark: true), values.2, token.name)
        }
    }

    func testActiveColourAndNotificationFollowFormChanges() {
        HousePalette.apply(.paper)
        defer { HousePalette.apply(.paper) }
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let color = HousePalette.paper.uiColor
        XCTAssertEqual(color.resolvedColor(with: dark), HousePalette.paper.resolved(in: .paper, appearance: dark))
        let change = expectation(forNotification: HousePalette.didChangeNotification, object: nil)
        XCTAssertTrue(HousePalette.apply(.standard))
        XCTAssertFalse(HousePalette.apply(.standard))
        wait(for: [change], timeout: 1)
        XCTAssertEqual(color.resolvedColor(with: dark), HousePalette.paper.resolved(in: .standard, appearance: dark))
    }
}
#endif
