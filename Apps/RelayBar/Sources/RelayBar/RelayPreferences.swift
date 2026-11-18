import Composition
import Foundation

/// What the user chose in RelayBar's Settings. Saved profiles, history and access grants live in their own stores.
struct RelayBarPreferences: Codable, Equatable {
    struct Preview: Codable, Equatable {
        var enabled = true
        var maximumBytes: Int64
    }

    var retryLimit = 10
    var automaticallyChecksForUpdates = false
    /// Only formats the user changed are stored; every other format uses its default.
    var previews: [String: Preview] = [:]
    /// Only plugins the user switched away from their default are stored.
    var plugins = PluginChoices()

    @MainActor
    func preview(_ kind: String) -> Preview {
        previews[kind] ?? Preview(maximumBytes: Self.defaultLimit(kind))
    }

    @MainActor
    static func defaultLimit(_ kind: String) -> Int64 {
        RemotePreviewPlugins.descriptors.first { $0.id == kind }?.maximumBytes ?? 0
    }

    @MainActor
    func validate() throws {
        guard TunnelStore.retryLimitRange.contains(retryLimit) else { throw CompositionError("Invalid SSH retry limit.") }
        for (kind, preview) in previews {
            guard let limit = RemotePreviewPlugins.descriptors.first(where: { $0.id == kind })?.maximumBytes,
                  preview.maximumBytes > 0, preview.maximumBytes <= limit else {
                throw CompositionError("Invalid preview size limit.")
            }
        }
    }

    /// Read once, the first time the preference document is created.
    @MainActor
    static func legacy(_ defaults: UserDefaults) -> RelayBarPreferences {
        var value = RelayBarPreferences()
        let saved = defaults.object(forKey: "sshRetryLimit.v1") as? Int ?? 10
        value.retryLimit = min(max(saved, TunnelStore.retryLimitRange.lowerBound), TunnelStore.retryLimitRange.upperBound)
        value.automaticallyChecksForUpdates = defaults.bool(forKey: "SUEnableAutomaticChecks")
        return value
    }
}

extension RelayBarPreferences {
    /// A document saved before plugins existed has no `plugins` key and loads with every plugin at its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retryLimit = try container.decode(Int.self, forKey: .retryLimit)
        automaticallyChecksForUpdates = try container.decode(Bool.self, forKey: .automaticallyChecksForUpdates)
        previews = try container.decode([String: Preview].self, forKey: .previews)
        plugins = try container.decodeIfPresent(PluginChoices.self, forKey: .plugins) ?? PluginChoices()
    }
}
