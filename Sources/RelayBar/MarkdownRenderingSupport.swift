import AppKit
import CryptoKit
import Foundation
import Highlighter
import MarkdownUI
import SwiftMath
import SwiftUI

/// HighlighterSwift is not Sendable-annotated. Every cache and JavaScriptCore
/// access in this adapter is serialized by `lock`.
final class RelayBarCodeSyntaxHighlighter: CodeSyntaxHighlighter, @unchecked Sendable {
    static let light = RelayBarCodeSyntaxHighlighter(isDark: false)
    static let dark = RelayBarCodeSyntaxHighlighter(isDark: true)

    static let maximumHighlightedByteCount = 64 * 1_024

    private let highlighter: Highlighter?
    private let appearanceKey: String
    private let supportedLanguages: Set<String>
    private let cache = NSCache<NSString, NSAttributedString>()
    private let failedCache = NSCache<NSString, NSNumber>()
    private let lock = NSLock()

    private init(isDark: Bool) {
        let highlighter = Highlighter()
        highlighter?.setTheme(
            isDark ? "github-dark" : "github",
            withFont: "Menlo-Regular",
            ofSize: 12
        )
        self.highlighter = highlighter
        appearanceKey = isDark ? "dark" : "light"
        supportedLanguages = Set(highlighter?.supportedLanguages() ?? [])
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1_024 * 1_024
        failedCache.countLimit = 128
    }

    func highlightCode(_ code: String, language: String?) -> Text {
        guard
            code.utf8.count <= Self.maximumHighlightedByteCount,
            let language = normalizedLanguage(language),
            supportedLanguages.contains(language)
        else {
            return Text(code)
        }

        // Digest rather than the code itself: this runs inside a SwiftUI render
        // pass, and a literal key would copy and hash up to 64 KB per lookup.
        let key = Self.cacheKey(appearance: appearanceKey, language: language, code: code)

        lock.lock()
        defer { lock.unlock() }

        if let cached = cache.object(forKey: key) {
            return Text(AttributedString(cached))
        }
        if failedCache.object(forKey: key) != nil {
            return Text(code)
        }

        guard let highlighted = highlighter?.highlight(code, as: language) else {
            failedCache.setObject(NSNumber(value: true), forKey: key)
            return Text(code)
        }

        let immutable = NSAttributedString(attributedString: highlighted)
        cache.setObject(immutable, forKey: key, cost: code.utf16.count)
        return Text(AttributedString(immutable))
    }

    static func cacheKey(appearance: String, language: String, code: String) -> NSString {
        var hasher = SHA256()
        hasher.update(data: Data(appearance.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(language.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(code.utf8))
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest as NSString
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        guard
            let rawLanguage = language?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first?
                .lowercased(),
            !rawLanguage.isEmpty
        else {
            return nil
        }

        let aliases = [
            "c++": "cpp",
            "cs": "csharp",
            "html": "xml",
            "js": "javascript",
            "jsx": "javascript",
            "md": "markdown",
            "objc": "objectivec",
            "py": "python",
            "rb": "ruby",
            "sh": "bash",
            "shell": "bash",
            "ts": "typescript",
            "tsx": "typescript",
            "yml": "yaml"
        ]
        return aliases[rawLanguage] ?? rawLanguage
    }
}

struct RemoteMathImage: Sendable {
    let data: Data
    let width: Double
    let height: Double

    var size: CGSize {
        CGSize(width: width, height: height)
    }

    func makeImage(formula: String) -> NSImage? {
        guard let image = NSImage(data: data) else {
            return nil
        }
        image.size = size
        image.isTemplate = true
        image.accessibilityDescription = "Math formula: \(formula)"
        return image
    }
}

actor RemoteMathRenderer {
    static let shared = RemoteMathRenderer()

    private static let maximumDisplaySize = CGSize(width: 1_600, height: 500)
    private static let maximumInlineSize = CGSize(width: 360, height: 26)
    private let cache = NSCache<NSString, CachedRemoteMathImage>()

    private final class CachedRemoteMathImage {
        let value: RemoteMathImage

        init(_ value: RemoteMathImage) {
            self.value = value
        }
    }

    init() {
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1_024 * 1_024
    }

    nonisolated static func canParse(_ formula: String) -> Bool {
        var error: NSError?
        return MTMathListBuilder.build(fromString: formula, error: &error) != nil
            && error == nil
    }

    func image(for formula: String, display: Bool) -> RemoteMathImage? {
        guard
            !formula.isEmpty,
            formula.count <= ObsidianMarkdownCompatibility.maximumFormulaCharacterCount
        else {
            return nil
        }

        let cacheKey = "\(display ? "display" : "inline")|\(formula)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.value
        }

        let renderer = MTMathImage(
            latex: formula,
            fontSize: display ? 22 : 16,
            textColor: .black,
            labelMode: display ? .display : .text,
            textAlignment: display ? .center : .left
        )
        let (error, renderedImage) = renderer.asImage()
        guard error == nil, let renderedImage, renderedImage.size.width > 0, renderedImage.size.height > 0 else {
            return nil
        }

        let maximumSize = display ? Self.maximumDisplaySize : Self.maximumInlineSize
        let scale = min(
            1,
            maximumSize.width / renderedImage.size.width,
            maximumSize.height / renderedImage.size.height
        )
        renderedImage.size = CGSize(
            width: max(1, renderedImage.size.width * scale),
            height: max(1, renderedImage.size.height * scale)
        )
        guard let data = renderedImage.tiffRepresentation else {
            return nil
        }
        let image = RemoteMathImage(
            data: data,
            width: renderedImage.size.width,
            height: renderedImage.size.height
        )
        cache.setObject(
            CachedRemoteMathImage(image),
            forKey: cacheKey,
            cost: data.count
        )
        return image
    }
}

enum RemoteMathImageLayout {
    static func fittedSize(for imageSize: CGSize, maximumSize: CGSize) -> CGSize {
        guard
            imageSize.width > 0,
            imageSize.height > 0,
            maximumSize.width > 0,
            maximumSize.height > 0
        else {
            return .zero
        }

        let scale = min(
            1,
            maximumSize.width / imageSize.width,
            maximumSize.height / imageSize.height
        )
        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }
}

struct SafeMarkdownImageProvider: ImageProvider {
    let referenceToken: String

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if
            let url,
            let math = ObsidianMarkdownCompatibility.internalValue(
                from: url,
                expectedScheme: "relaybar-math",
                referenceToken: referenceToken
            ),
            ["inline", "display"].contains(math.kind)
        {
            MarkdownMathBlock(formula: math.value, display: math.kind == "display")
        } else {
            BlockedMarkdownImage()
        }
    }
}

struct SafeMarkdownInlineImageProvider: InlineImageProvider {
    let referenceToken: String

    func image(with url: URL, label: String) async throws -> Image {
        if
            let math = ObsidianMarkdownCompatibility.internalValue(
                from: url,
                expectedScheme: "relaybar-math",
                referenceToken: referenceToken
            ),
            ["inline", "display"].contains(math.kind),
            let renderedImage = await RemoteMathRenderer.shared.image(
                for: math.value,
                display: math.kind == "display"
            ),
            let image = renderedImage.makeImage(formula: math.value)
        {
            return Image(nsImage: image)
        }

        let description = label.isEmpty
            ? "Remote Markdown image not loaded"
            : "\(label), remote Markdown image not loaded"
        guard
            let symbol = NSImage(
                systemSymbolName: "photo.badge.exclamationmark",
                accessibilityDescription: description
            )
        else {
            throw RemoteFileError.unsupportedImage
        }
        return Image(nsImage: symbol)
    }
}

private struct MarkdownMathBlock: View {
    let formula: String
    let display: Bool

    @State private var image: NSImage?
    @State private var didFail = false

    nonisolated init(formula: String, display: Bool) {
        self.formula = formula
        self.display = display
    }

    var body: some View {
        Group {
            if let image {
                let fittedSize = RemoteMathImageLayout.fittedSize(
                    for: image.size,
                    maximumSize: CGSize(
                        width: display ? 780 : 360,
                        height: display ? 180 : 26
                    )
                )
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .foregroundStyle(.primary)
            } else if didFail {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Math could not be rendered", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(formula)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: display ? 54 : 28, alignment: .center)
        .padding(display ? 14 : 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Math formula \(formula)")
        .task(id: "\(display)|\(formula)") {
            image = nil
            didFail = false
            let renderedImage = await RemoteMathRenderer.shared.image(
                for: formula,
                display: display
            )
            image = renderedImage?.makeImage(formula: formula)
            didFail = image == nil
        }
    }
}

private struct BlockedMarkdownImage: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
            Text("Image not loaded")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 72)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.09))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote Markdown image not loaded")
    }
}
