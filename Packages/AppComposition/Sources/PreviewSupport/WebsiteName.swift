import Foundation

public enum WebsiteName {
    public static let byteLimit = 64 * 1_024
    /// Products known by a word in the page title or a marker in the page, tried in order.
    /// Stable Diffusion WebUI and Open WebUI come before Gradio, which pages of theirs may embed.
    private static let products: [(name: String, titles: [String], markers: [String])] = [
        ("ComfyUI", ["comfyui"], []),
        ("Jupyter", ["jupyter"], ["jupyter-config-data"]),
        ("TensorBoard", ["tensorboard"], ["<tf-tensorboard", "<tb-webapp"]),
        ("Stable Diffusion WebUI", ["stable diffusion"], []),
        ("Open WebUI", ["open webui"], []),
        ("Gradio", ["gradio"], ["window.gradio_config", "<gradio-app"])
    ]
    private static let titleLimit = 40

    /// Names what answered from its status, its headers (with lowercased names) and the bytes read.
    /// Any response means the port is responding. A redirect that was not followed, or a body that is
    /// not HTML, has no name.
    public static func recognizing(status: Int, contentType: String?, body: Data, excluding token: String? = nil) -> String? {
        guard !(300..<400).contains(status) else { return nil }
        if let type = contentType, !type.lowercased().contains("html") {
            return nil
        }
        let page = String(decoding: body, as: UTF8.self)
        let title = pageTitle(page)
        if let token, title?.contains(token) == true { return nil }
        let lowercasedTitle = title?.lowercased() ?? ""
        let lowercasedPage = page.lowercased()
        let product = products.first { product in
            product.titles.contains { lowercasedTitle.contains($0) }
                || product.markers.contains { lowercasedPage.contains($0) }
        }
        if let product {
            return product.name
        }
        guard let title else { return nil }
        return String(title.prefix(titleLimit))
    }

    /// The text of the first `<title>` element with its whitespace collapsed, or nil when it has none.
    private static func pageTitle(_ page: String) -> String? {
        guard
            let open = page.range(of: "<title", options: .caseInsensitive),
            let start = page.range(of: ">", range: open.upperBound..<page.endIndex),
            let end = page.range(of: "</title", options: .caseInsensitive, range: start.upperBound..<page.endIndex)
        else {
            return nil
        }
        // The title is the remote page's text: control and invisible formatting characters are dropped.
        let visible = String(String.UnicodeScalarView(page[start.upperBound..<end.lowerBound].unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format
                || scalar.properties.isWhitespace
        }))
        let words = visible.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }
}
