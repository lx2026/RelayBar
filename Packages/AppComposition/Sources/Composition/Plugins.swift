import Foundation

/// An optional part of an app that a person may switch on or off. Each app declares its catalog in one place.
public struct PluginDescriptor: Identifiable, Equatable, Sendable {
    /// The stable key stored in the person's choices.
    public let id: String
    public let title: String
    /// One sentence saying what the plugin adds.
    public let summary: String
    /// An SF Symbol name.
    public let symbol: String
    public let isOnByDefault: Bool
    /// The full feature ids this plugin contributes while it is on.
    public let features: [String]

    /// Declares a plugin.
    public init(id: String, title: String, summary: String, symbol: String, isOnByDefault: Bool, features: [String]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.isOnByDefault = isOnByDefault
        self.features = features
    }
}

/// The person's plugin choices, stored as overrides of each plugin's default.
/// Encodes as a plain JSON object of plugin ids, such as `{"services": true}`.
public struct PluginChoices: Codable, Equatable, Sendable {
    /// The plugins whose state differs from their default, and any pinned choice.
    public private(set) var overrides: [String: Bool]

    /// No overrides: every plugin follows its default.
    public init() {
        overrides = [:]
    }

    /// Whether the plugin is on, after any override.
    public func isEnabled(_ plugin: PluginDescriptor) -> Bool {
        overrides[plugin.id] ?? plugin.isOnByDefault
    }

    /// Records a choice. A choice equal to the default removes the override instead of storing it.
    public mutating func set(_ plugin: PluginDescriptor, enabled: Bool) {
        if enabled == plugin.isOnByDefault {
            overrides[plugin.id] = nil
        } else {
            overrides[plugin.id] = enabled
        }
    }

    /// Records a choice and keeps it even when it equals the default, for a plugin whose default
    /// can differ from one launch to the next.
    public mutating func pin(_ plugin: PluginDescriptor, enabled: Bool) {
        overrides[plugin.id] = enabled
    }

    /// Reads a plain object of plugin ids.
    public init(from decoder: Decoder) throws {
        overrides = try decoder.singleValueContainer().decode([String: Bool].self)
    }

    /// Writes a plain object of plugin ids.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(overrides)
    }
}
