import Composition
import Foundation
import XCTest

final class PluginChoicesTests: XCTestCase {
    private let services = PluginDescriptor(id: "services", title: "Services", summary: "Adds services.",
                                            symbol: "gearshape", isOnByDefault: true, features: ["services"])
    private let places = PluginDescriptor(id: "places", title: "Places", summary: "Shows places.",
                                          symbol: "map", isOnByDefault: false, features: ["places"])

    func testDefaultsApplyUntilSomethingIsChanged() {
        let choices = PluginChoices()
        XCTAssertTrue(choices.isEnabled(services))
        XCTAssertFalse(choices.isEnabled(places))
        XCTAssertEqual(choices.overrides, [:])
    }

    func testOnlyChangesAreStoredAndSettingTheDefaultRemovesThem() {
        var choices = PluginChoices()
        choices.set(services, enabled: true)
        XCTAssertEqual(choices.overrides, [:])
        choices.set(services, enabled: false)
        choices.set(places, enabled: true)
        XCTAssertEqual(choices.overrides, ["services": false, "places": true])
        XCTAssertFalse(choices.isEnabled(services))
        XCTAssertTrue(choices.isEnabled(places))
        choices.set(services, enabled: true)
        XCTAssertEqual(choices.overrides, ["places": true])
        XCTAssertTrue(choices.isEnabled(services))
    }

    func testAPinnedChoiceIsKeptWhenItEqualsTheDefaultAndOutlastsADifferentDefault() {
        var choices = PluginChoices()
        choices.pin(services, enabled: true)
        XCTAssertEqual(choices.overrides, ["services": true])
        let laterServices = PluginDescriptor(id: "services", title: "Services", summary: "Adds services.",
                                             symbol: "gearshape", isOnByDefault: false, features: ["services"])
        XCTAssertTrue(choices.isEnabled(laterServices))
        choices.pin(places, enabled: false)
        XCTAssertEqual(choices.overrides, ["services": true, "places": false])
        choices.set(services, enabled: true)
        XCTAssertEqual(choices.overrides, ["places": false], "An ordinary choice still drops what equals the default")
    }

    func testChoicesAreAPlainJSONObject() throws {
        var choices = PluginChoices()
        choices.set(services, enabled: false)
        choices.set(places, enabled: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(choices), as: UTF8.self), #"{"places":true,"services":false}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(PluginChoices()), as: UTF8.self), "{}")

        let decoded = try JSONDecoder().decode(PluginChoices.self, from: Data(#"{"services": true}"#.utf8))
        XCTAssertEqual(decoded.overrides, ["services": true])
        XCTAssertTrue(decoded.isEnabled(services))
        XCTAssertFalse(decoded.isEnabled(places))
        XCTAssertThrowsError(try JSONDecoder().decode(PluginChoices.self, from: Data(#"{"overrides": {}}"#.utf8)))
    }
}
