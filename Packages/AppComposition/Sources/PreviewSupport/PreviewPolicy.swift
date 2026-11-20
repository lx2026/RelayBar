import Composition

public enum PreviewFileTypes {
    public static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd"]
    public static let html: Set<String> = ["html", "htm"]
    public static let json: Set<String> = ["json"]
    public static let notebook: Set<String> = ["ipynb"]
    public static let table: Set<String> = ["csv", "tsv"]
    public static let text: Set<String> = [
        "c", "conf", "cpp", "css", "go", "h", "hpp", "ini", "java", "js", "jsonl", "jsx", "log", "py",
        "rb", "rs", "sh", "sql", "swift", "text", "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
    ]
    public static let video: Set<String> = ["mp4", "mov", "m4v"]
    public static let coreImages: Set<String> = ["jpg", "jpeg", "png"]
    public static let additionalImages: Set<String> = ["bmp", "gif", "heic", "heif", "tif", "tiff", "webp"]
    private static let allImages = coreImages.union(additionalImages)
    public static func images(extended: Bool) -> Set<String> {
        extended ? allImages : coreImages
    }
}

public enum PreviewLimits {
  public static let pngChunk = 1 << 20
  public static let pngText = 2 << 20
    public static let document = 10 << 20
    public static let asset = 32 << 20
    public static let page = 64 << 20
    public static let requests = 128
    public static let original = 100 << 20
    public static let entries = 10_000
    public static let companions = 32
    public static let companionBytes = 2 << 20
    public static let companionCharacters = 256_000

    public static func companionText(_ text: String, remaining: inout Int) -> String {
        let prefix = text.unicodeScalars.prefix(remaining)
        remaining -= prefix.count
        return String(prefix)
    }
}

public enum PreviewPlugins {
    public static let moreImages = PluginDescriptor(
        id: "more-images", title: "More Image Formats",
        summary: "Preview BMP, GIF, HEIC, HEIF, TIFF and WebP images.",
        symbol: "photo.stack", isOnByDefault: true)
    public static let websiteTitle = "Website Labels"
    public static let websiteSummary = "Show the product name or page title of a website."
    public static let searchTitle = "Prompt Search"
    public static let searchSummary = "Find images by words in their prompts and notes."
}
