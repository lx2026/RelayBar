import Composition

/// The plugin that chooses the palette's form, listed in both apps' catalogs. It contributes no feature: it changes
/// how the shell draws, not what runs, so each app applies the stored choice itself, before its first window and
/// after every change.
public enum PaperAppearance {
    public static let plugin = PluginDescriptor(
        id: "paper",
        title: "Paper Appearance",
        summary: "Uses the warm paper colours of RelayBar and Frame in this app. Turn it off for standard macOS colours.",
        symbol: "paintpalette",
        isOnByDefault: true,
        features: []
    )

    /// Paper while the plugin is on, standard otherwise.
    public static func form(_ choices: PluginChoices) -> HouseForm {
        choices.isEnabled(plugin) ? .paper : .standard
    }
}
