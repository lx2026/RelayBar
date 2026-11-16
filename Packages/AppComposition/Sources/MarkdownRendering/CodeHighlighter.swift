import AppKit
import Foundation
import Highlighter

/// Highlights a code block once for each appearance. The page shows whichever matches.
final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()
    static let maximumHighlightedByteCount = 64 * 1_024

    struct Markup { let light: String; let dark: String }
    private final class Cached { let value: Markup; init(_ value: Markup) { self.value = value } }

    private let lock = NSLock()
    private var loaded = false
    private var light: Highlighter?
    private var dark: Highlighter?
    private var supportedLanguages: Set<String> = []
    private let cache = NSCache<NSString, Cached>()

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1_024 * 1_024
    }

    /// Nil when the block has no language, an unknown one, or is too large: it is then shown plain.
    func html(for code: String, language rawLanguage: String?) -> Markup? {
        guard code.utf8.count <= Self.maximumHighlightedByteCount, let rawLanguage, !rawLanguage.isEmpty else { return nil }
        let language = Self.aliases[rawLanguage] ?? rawLanguage
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            light = Self.engine(theme: "github")
            dark = Self.engine(theme: "github-dark")
            supportedLanguages = Set(light?.supportedLanguages() ?? [])
        }
        guard supportedLanguages.contains(language), let light, let dark else { return nil }
        // Interpolated rather than digested: NSString bridging is lazy and NSCache does not hash the whole string.
        let key = "\(language)|\(code)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        guard let lightText = light.highlight(code, as: language), let darkText = dark.highlight(code, as: language) else { return nil }
        let markup = Markup(light: Self.markup(lightText), dark: Self.markup(darkText))
        cache.setObject(Cached(markup), forKey: key, cost: code.utf16.count * 6)
        return markup
    }

    private static func engine(theme: String) -> Highlighter? {
        guard let highlighter = Highlighter() else { return nil }
        guard highlighter.setTheme(theme, withFont: "Menlo-Regular", ofSize: 12) else { return nil }
        return highlighter
    }

    private static func markup(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let piece = MarkdownRenderer.escaped(text.attributedSubstring(from: range).string)
            var style = ""
            if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                style += String(format: "color:#%02x%02x%02x;",
                                Int((color.redComponent * 255).rounded()),
                                Int((color.greenComponent * 255).rounded()),
                                Int((color.blueComponent * 255).rounded()))
            }
            if let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits {
                if traits.contains(.bold) { style += "font-weight:600;" }
                if traits.contains(.italic) { style += "font-style:italic;" }
            }
            let blank = piece.allSatisfy { $0 == " " || $0 == "\n" || $0 == "\t" }
            result += style.isEmpty || blank ? piece : "<span style=\"\(style)\">\(piece)</span>"
        }
        return result
    }

    private static let aliases = [
        "c++": "cpp", "cs": "csharp", "html": "xml", "js": "javascript", "jsx": "javascript",
        "md": "markdown", "objc": "objectivec", "py": "python", "rb": "ruby", "sh": "bash",
        "shell": "bash", "ts": "typescript", "tsx": "typescript", "yml": "yaml", "zsh": "bash"
    ]
}
