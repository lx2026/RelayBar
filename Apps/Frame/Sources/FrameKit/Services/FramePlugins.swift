import PreviewSupport
import Composition
import HouseStyle

/// Frame's optional features, declared in one place. A plugin's nodes are part of the tree only while it is on.
public enum FramePlugins {
    /// Filters the current folder by the words in each asset's file name and companion text.
    public static let promptSearch = PluginDescriptor(
        id: "prompt-search",
        title: PreviewPlugins.searchTitle,
        summary: PreviewPlugins.searchSummary,
        symbol: "text.magnifyingglass",
        isOnByDefault: true,
        features: ["prompt-search", "remote/prompt-search"]
    )

    /// The palette's form, shared with RelayBar.
    public static let paperAppearance = PaperAppearance.plugin

    /// The catalog, in the order the Plugins window lists it.
    public static let all = [promptSearch, paperAppearance, PreviewPlugins.moreImages]
}
