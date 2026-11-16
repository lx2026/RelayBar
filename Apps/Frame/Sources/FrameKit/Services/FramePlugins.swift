import Composition

/// Frame's optional features, declared in one place. A plugin's nodes are part of the tree only while it is on.
public enum FramePlugins {
    /// Filters the current folder by the words in each asset's file name and companion text.
    public static let promptSearch = PluginDescriptor(
        id: "prompt-search",
        title: "Prompt Search",
        summary: "Filters the current folder by words in each asset's prompt and notes.",
        symbol: "text.magnifyingglass",
        isOnByDefault: true,
        features: ["prompt-search", "remote/prompt-search"]
    )

    /// The catalog, in the order the Plugins window lists it.
    public static let all = [promptSearch]
}
