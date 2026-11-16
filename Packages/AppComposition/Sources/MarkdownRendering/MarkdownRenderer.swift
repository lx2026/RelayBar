import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// A Markdown document as a static page: no script, nothing to fetch but what the
/// host's own rules allow, and every link the document wrote left for the host to judge.
public struct MarkdownPage: Sendable, Equatable {
    /// `<article class="markdown">…</article>`.
    public let html: String
    public let plainText: String
    /// The text of each code block in document order, for the Copy links.
    public let codeBlocks: [String]
    /// With indexed links, each link's destination as the document wrote it. Empty otherwise.
    public let links: [String]

    public static let empty = MarkdownPage(html: "<article class=\"markdown\"></article>", plainText: "", codeBlocks: [], links: [])
}

/// What a link's address is in the page.
public enum MarkdownLinkHandling: Sendable {
    /// The destination itself, for a host that lets its web view follow links.
    case direct
    /// An opaque reference into `MarkdownPage.links`, so the page names no server and no file.
    /// A web view starts connecting to a link's server as soon as the link is clicked, before
    /// the host is asked whether to follow it; a reference gives it nothing to connect to.
    case indexed
}

public struct MarkdownRenderOptions: Sendable {
    /// Carried by every private link the renderer writes, so a link the document
    /// wrote itself can be told apart from one the renderer produced.
    public var referenceToken: String
    public var images: ObsidianMarkdownCompatibility.ImageHandling
    public var links: MarkdownLinkHandling
    /// Obsidian compatibility, highlighting and math. Off for documents too large for them.
    public var enriched: Bool

    /// Without a token of the caller's own, each set of options gets a fresh random one.
    public init(
        referenceToken: String = UUID().uuidString.lowercased(),
        images: ObsidianMarkdownCompatibility.ImageHandling = .placeholder,
        links: MarkdownLinkHandling = .direct,
        enriched: Bool = true
    ) {
        self.referenceToken = referenceToken
        self.images = images
        self.links = links
        self.enriched = enriched
    }
}

public enum MarkdownRenderer {
    /// Above this size a document is rendered without Obsidian compatibility, highlighting or math.
    public static let maximumEnrichedByteCount = 2 * 1_024 * 1_024
    public static let copyScheme = "relaybar-copy"
    public static let linkScheme = "relaybar-link"
    public static let mathScheme = "relaybar-math"
    private static let maximumImageLabelLength = 512

    private static let extensionsReady: Void = cmark_gfm_core_extensions_ensure_registered()

    /// Synchronous and safe to call off the main thread. Returns an empty page when
    /// the calling task is cancelled.
    public static func page(_ source: String, options: MarkdownRenderOptions = .init()) -> MarkdownPage {
        _ = extensionsReady
        let prepared = options.enriched
            ? ObsidianMarkdownCompatibility.renderSource(
                source,
                referenceToken: options.referenceToken,
                images: options.images,
                mathValidator: { MathTypesetter.canParse($0) }
            )
            : source
        // A cancelled compatibility pass hands back its input, which must not be shown as its result.
        guard !Task.isCancelled else { return .empty }

        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return .empty }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        prepared.withCString { cmark_parser_feed(parser, $0, prepared.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return .empty }
        defer { cmark_node_free(root) }

        let plainText = string(cmark_render_plaintext(root, CMARK_OPT_DEFAULT, 0))
        let (codeBlocks, links) = rewrite(root, options: options)
        guard !Task.isCancelled else { return .empty }
        // Safe mode: any raw HTML or unsafe URL the document still carries is left out.
        let body = string(cmark_render_html(root, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(parser)))
        return MarkdownPage(html: "<article class=\"markdown\">\(body)</article>", plainText: plainText, codeBlocks: codeBlocks, links: links)
    }

    /// The page with its stylesheet, ready to follow a host's own document head.
    public static func body(_ page: MarkdownPage, palette: String = "") -> String {
        "<style>\(stylesheet)\(palette)</style>\(page.html)"
    }

    /// The code block a Copy link names, if the link carries this page's token.
    public static func copiedBlockIndex(from url: URL, referenceToken: String) -> Int? {
        index(in: url, scheme: copyScheme, kind: "block", referenceToken: referenceToken)
    }

    /// The entry of `MarkdownPage.links` an indexed link names, if it carries this page's token.
    public static func linkedIndex(from url: URL, referenceToken: String) -> Int? {
        index(in: url, scheme: linkScheme, kind: "link", referenceToken: referenceToken)
    }

    private static func index(in url: URL, scheme: String, kind: String, referenceToken: String) -> Int? {
        guard
            let link = ObsidianMarkdownCompatibility.internalValue(
                from: url, expectedScheme: scheme, referenceToken: referenceToken),
            link.kind == kind, let index = Int(link.value), index >= 0
        else { return nil }
        return index
    }

    public static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Tree rewriting

    /// Replaces code blocks, math and images with markup the renderer wrote itself, and
    /// puts each table in a scrolling container. Returns the code blocks' text and, with indexed
    /// links, the destinations the links were given in place of.
    private static func rewrite(_ root: UnsafeMutablePointer<cmark_node>, options: MarkdownRenderOptions) -> (codeBlocks: [String], links: [String]) {
        var codeNodes: [UnsafeMutablePointer<cmark_node>] = []
        var imageNodes: [UnsafeMutablePointer<cmark_node>] = []
        var linkNodes: [UnsafeMutablePointer<cmark_node>] = []
        var tableNodes: [UnsafeMutablePointer<cmark_node>] = []
        if let iterator = cmark_iter_new(root) {
            defer { cmark_iter_free(iterator) }
            while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
                guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                      let node = cmark_iter_get_node(iterator) else { continue }
                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_CODE_BLOCK { codeNodes.append(node) }
                else if type == CMARK_NODE_IMAGE { imageNodes.append(node) }
                else if type == CMARK_NODE_LINK { linkNodes.append(node) }
                else if String(cString: cmark_node_get_type_string(node)) == "table" { tableNodes.append(node) }
            }
        }

        var codeBlocks: [String] = []
        for node in codeNodes {
            guard !Task.isCancelled else { break }
            let code = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
            let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
            let markup = codeFigure(code, info: info, index: codeBlocks.count, options: options)
            // A block that could not be replaced stays as the parser's own escaped code block.
            if replaceBlock(node, markup: markup) {
                codeBlocks.append(code.hasSuffix("\n") ? String(code.dropLast()) : code)
            }
        }
        var links: [String] = []
        for node in linkNodes {
            let destination = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
            switch options.links {
            case .indexed:
                let reference = ObsidianMarkdownCompatibility.internalURL(
                    scheme: linkScheme, kind: "link", value: String(links.count), referenceToken: options.referenceToken)
                cmark_node_set_url(node, reference?.absoluteString ?? "")
                if reference != nil { links.append(destination) }
            case .direct:
                // The parser's safe mode lets image-typed data: links through; no link may carry content.
                if destination.drop(while: { $0.isWhitespace }).lowercased().hasPrefix("data:") { cmark_node_set_url(node, "") }
            }
        }
        // Innermost first: an image inside another image's label is freed with its parent.
        for node in imageNodes.reversed() {
            guard !Task.isCancelled else { break }
            let destination = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
            if destination.lowercased().hasPrefix(mathScheme + ":") {
                if let markup = mathMarkup(destination, options: options) {
                    replaceInline(node, markup: markup)
                } else {
                    // A math link the document wrote itself: it never had this page's token.
                    replaceWithNotLoaded(node, label: "Math formula")
                }
            } else if options.images == .placeholder {
                // The compatibility pass has already replaced the images it recognised.
                let label = text(in: node)
                replaceWithNotLoaded(node, label: label.isEmpty ? "Unlabelled image" : label)
            }
        }
        for node in tableNodes {
            guard let wrapper = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            cmark_node_set_on_enter(wrapper, "<div class=\"table-scroll\">")
            cmark_node_set_on_exit(wrapper, "</div>")
            guard cmark_node_insert_before(node, wrapper) == 1 else { cmark_node_free(wrapper); continue }
            cmark_node_unlink(node)
            if cmark_node_append_child(wrapper, node) != 1 {
                cmark_node_insert_after(wrapper, node)
                cmark_node_unlink(wrapper)
                cmark_node_free(wrapper)
            }
        }
        return (codeBlocks, links)
    }

    private static func replaceBlock(_ node: UnsafeMutablePointer<cmark_node>, markup: String) -> Bool {
        guard let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { return false }
        cmark_node_set_on_enter(replacement, markup)
        guard cmark_node_replace(node, replacement) == 1 else { cmark_node_free(replacement); return false }
        cmark_node_free(node)
        return true
    }

    /// Puts the renderer's own markup where an image was. Whatever happens, the image itself is removed.
    private static func replaceInline(_ node: UnsafeMutablePointer<cmark_node>, markup: String) {
        defer { cmark_node_unlink(node); cmark_node_free(node) }
        guard let custom = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { return }
        cmark_node_set_on_enter(custom, markup)
        if cmark_node_insert_before(node, custom) == 1 { return }
        // A table cell accepts only a few kinds of inline. Emphasis is one of them and may hold any inline.
        guard let wrapper = cmark_node_new(CMARK_NODE_EMPH) else { cmark_node_free(custom); return }
        guard cmark_node_append_child(wrapper, custom) == 1 else { cmark_node_free(custom); cmark_node_free(wrapper); return }
        if cmark_node_insert_before(node, wrapper) != 1 { cmark_node_free(wrapper) }
    }

    /// Replaces an image with ordinary text nodes, which every container accepts.
    private static func replaceWithNotLoaded(_ node: UnsafeMutablePointer<cmark_node>, label: String) {
        defer { cmark_node_unlink(node); cmark_node_free(node) }
        guard let strong = cmark_node_new(CMARK_NODE_STRONG), let title = cmark_node_new(CMARK_NODE_TEXT) else { return }
        cmark_node_set_literal(title, "Image not loaded:")
        guard cmark_node_append_child(strong, title) == 1 else { cmark_node_free(title); cmark_node_free(strong); return }
        guard cmark_node_insert_before(node, strong) == 1 else { cmark_node_free(strong); return }
        guard let rest = cmark_node_new(CMARK_NODE_TEXT) else { return }
        cmark_node_set_literal(rest, " " + label)
        if cmark_node_insert_before(node, rest) != 1 { cmark_node_free(rest) }
    }

    /// The text of an image's label. Iterative and bounded: a label can nest as deeply as the document likes.
    private static func text(in node: UnsafeMutablePointer<cmark_node>) -> String {
        guard let iterator = cmark_iter_new(node) else { return "" }
        defer { cmark_iter_free(iterator) }
        var result = ""
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE, result.count < maximumImageLabelLength {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER,
                  let current = cmark_iter_get_node(iterator), current != node,
                  let literal = cmark_node_get_literal(current) else { continue }
            result += String(cString: literal)
        }
        return String(result.prefix(maximumImageLabelLength))
    }

    private static func codeFigure(_ code: String, info: String, index: Int, options: MarkdownRenderOptions) -> String {
        let language = info.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
        let trimmed = code.hasSuffix("\n") ? String(code.dropLast()) : code
        let copy = ObsidianMarkdownCompatibility.internalURL(
            scheme: copyScheme, kind: "block", value: String(index), referenceToken: options.referenceToken)
        var markup = "<figure class=\"code\"><figcaption><div class=\"bar\"><span class=\"language\">"
        markup += escaped(language ?? "plain text") + "</span>"
        if let copy { markup += "<a class=\"copy\" role=\"button\" href=\"\(escaped(copy.absoluteString))\">Copy</a>" }
        markup += "</div>"
        if language == "mermaid" {
            markup += "<div class=\"note\">Diagram source only — Mermaid code is not executed</div>"
        }
        markup += "</figcaption>"
        if options.enriched, let highlighted = CodeHighlighter.shared.html(for: trimmed, language: language) {
            markup += "<pre class=\"light\"><code>\(highlighted.light)</code></pre>"
            markup += "<pre class=\"dark\"><code>\(highlighted.dark)</code></pre>"
        } else {
            markup += "<pre><code>\(escaped(trimmed))</code></pre>"
        }
        return markup + "</figure>"
    }

    /// Nil unless the link is one this page's compatibility pass wrote.
    private static func mathMarkup(_ destination: String, options: MarkdownRenderOptions) -> String? {
        guard
            let url = URL(string: destination),
            let math = ObsidianMarkdownCompatibility.internalValue(
                from: url, expectedScheme: mathScheme, referenceToken: options.referenceToken),
            ["inline", "display"].contains(math.kind)
        else { return nil }
        let display = math.kind == "display"
        guard options.enriched, let image = MathTypesetter.image(for: math.value, display: display) else {
            let source = "<code class=\"math-source\">\(escaped(math.value))</code>"
            return display ? "<span class=\"math-display failed\"><span class=\"note\">Math could not be rendered</span>\(source)</span>" : source
        }
        let tag = "<img class=\"math\" alt=\"\(escaped("Math formula: " + math.value))\" "
            + "width=\"\(number(image.width))\" height=\"\(number(image.height))\" "
            + (display ? "" : "style=\"vertical-align:-\(number(image.descent))px\" ")
            + "src=\"data:image/png;base64,\(image.png.base64EncodedString())\">"
        return display ? "<span class=\"math-display\">\(tag)</span>" : tag
    }

    private static func number(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
