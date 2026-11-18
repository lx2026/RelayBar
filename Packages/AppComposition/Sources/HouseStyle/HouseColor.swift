import AppKit
import Combine
import Observation
import SwiftUI

public extension HouseToken {
    /// The colour for SwiftUI. A view that reads it while drawing its body is drawn again when the form changes,
    /// keeping its state; on macOS 13 that needs a `HouseTracking` property in the view.
    var color: Color {
        HouseFormTracking.read()
        return swiftUI[HousePalette.form] ?? Color(nsColor: nsColor)
    }
}

/// The house palette's tokens for SwiftUI.
public enum HouseColor {
    public static var paper: Color { HousePalette.paper.color }
    public static var panel: Color { HousePalette.panel.color }
    public static var stage: Color { HousePalette.stage.color }
    public static var card: Color { HousePalette.card.color }
    public static var selected: Color { HousePalette.selected.color }
    public static var ink: Color { HousePalette.ink.color }
    public static var muted: Color { HousePalette.muted.color }
    public static var faint: Color { HousePalette.faint.color }
    public static var line: Color { HousePalette.line.color }
    public static var fill: Color { HousePalette.fill.color }
    public static var amber: Color { HousePalette.amber.color }
    public static var red: Color { HousePalette.red.color }
    public static var button: Color { HousePalette.button.color }
    public static var buttonText: Color { HousePalette.buttonText.color }
    public static var running: Color { HousePalette.running.color }
    public static var retrying: Color { HousePalette.retrying.color }
    public static var warning: Color { HousePalette.warning.color }
    public static var failure: Color { HousePalette.failure.color }
}

/// Declare in every view whose body reads a house colour: `@HouseTracking private var house`. From macOS 14 SwiftUI
/// sees the read itself and this only reports the form. On macOS 13, where it cannot, the property makes SwiftUI draw
/// the view's body again in place when the form changes, so the view keeps its state.
@propertyWrapper
public struct HouseTracking: DynamicProperty {
    @ObservedObject private var legacy = HouseFormTracking.legacy

    public init() {}

    /// The active form, read so that a change redraws the view.
    public var wrappedValue: HouseForm {
        HouseFormTracking.read()
        return HousePalette.form
    }
}

/// How SwiftUI learns that the form changed.
enum HouseFormTracking {
    /// Observed by every `HouseTracking` property.
    static let legacy = LegacyForm()
    /// Lets a test take the macOS 13 path on a later system.
    nonisolated(unsafe) static var usesObservation = true

    static func read() {
        guard usesObservation else { return }
        if #available(macOS 14, *) { ObservedForm.shared.read() }
    }

    @MainActor static func changed(to form: HouseForm) {
        if #available(macOS 14, *) { ObservedForm.shared.changed() }
        legacy.value = form
    }

    /// Published on the main thread only.
    final class LegacyForm: ObservableObject, @unchecked Sendable {
        @Published var value = HousePalette.form
    }
}

/// Registers a read of the form with Observation, which SwiftUI tracks in every body it draws.
@available(macOS 14, *)
private final class ObservedForm: Observable, @unchecked Sendable {
    static let shared = ObservedForm()
    private let registrar = ObservationRegistrar()
    private var generation = 0

    func read() {
        registrar.access(self, keyPath: \.generation)
    }

    func changed() {
        registrar.withMutation(of: self, keyPath: \.generation) { generation += 1 }
    }
}

/// A hairline in the line colour where a `Divider` would go, with the divider's own size and direction.
public struct HouseDivider: View {
    @HouseTracking private var house

    public init() {}

    public var body: some View {
        Divider().hidden().overlay(HousePalette.line.color)
    }
}
