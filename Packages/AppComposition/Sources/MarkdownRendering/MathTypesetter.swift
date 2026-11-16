import AppKit
import Foundation
import SwiftMath

/// A typeset formula, drawn in black on a clear ground; the stylesheet inverts it in dark appearance.
struct TypesetMath: Sendable {
    let png: Data
    let width: Double
    let height: Double
    /// How far the image's bottom edge sits below the text baseline.
    let descent: Double
}

public enum MathTypesetter {
    private static let maximumDisplaySize = CGSize(width: 1_600, height: 500)
    private static let maximumInlineSize = CGSize(width: 360, height: 26)
    private static let pixelsPerPoint: CGFloat = 2
    private static let lock = NSLock()
    private final class Cached { let value: TypesetMath; init(_ value: TypesetMath) { self.value = value } }
    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    static let maximumNestingDepth = 32

    /// Whether a formula can be typeset. Stricter than the parser: the typesetter traps on some lists
    /// the parser accepts, and both recurse as deeply as the formula nests.
    public static func canParse(_ formula: String) -> Bool {
        guard formula.count <= ObsidianMarkdownCompatibility.maximumFormulaCharacterCount, nesting(of: formula) <= maximumNestingDepth else { return false }
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: formula, error: &error), error == nil else { return false }
        return isSafeToTypeset(list, depth: 0)
    }

    /// The deepest braces go, counting each `\left` and `\begin` as one more level.
    private static func nesting(of formula: String) -> Int {
        var depth = 0, deepest = 0
        for character in formula {
            if character == "{" { depth += 1; deepest = max(deepest, depth) } else if character == "}" { depth = max(0, depth - 1) }
        }
        return deepest + formula.components(separatedBy: "\\left").count - 1 + formula.components(separatedBy: "\\begin").count - 1
    }

    /// Colour commands are refused outright: the typesetter indexes into their contents without checking
    /// that there are any, and force-casts what it finds.
    private static func isSafeToTypeset(_ list: MTMathList?, depth: Int) -> Bool {
        guard let list else { return true }
        guard depth <= maximumNestingDepth else { return false }
        for atom in list.atoms {
            if atom is MTMathColor || atom is MTMathTextColor || atom is MTMathColorbox { return false }
            var children: [MTMathList?] = [atom.subScript, atom.superScript]
            if let fraction = atom as? MTFraction { children += [fraction.numerator, fraction.denominator] }
            if let radical = atom as? MTRadical { children += [radical.radicand, radical.degree] }
            if let inner = atom as? MTInner { children.append(inner.innerList) }
            if let line = atom as? MTOverLine { children.append(line.innerList) }
            if let line = atom as? MTUnderLine { children.append(line.innerList) }
            if let accent = atom as? MTAccent { children.append(accent.innerList) }
            if let table = atom as? MTMathTable { for row in table.cells { children += row.map(Optional.some) } }
            for child in children where !isSafeToTypeset(child, depth: depth + 1) { return false }
        }
        return true
    }

    static func image(for formula: String, display: Bool) -> TypesetMath? {
        guard !formula.isEmpty else { return nil }
        let key = "\(display ? "display" : "inline")|\(formula)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        guard canParse(formula) else { return nil }
        // The typesetter shares font tables between calls.
        lock.lock()
        defer { lock.unlock() }
        var renderer = MathImage(
            latex: formula,
            fontSize: display ? 22 : 16,
            textColor: .black,
            labelMode: display ? .display : .text,
            textAlignment: display ? .center : .left
        )
        let (error, rendered, layout) = renderer.asImage()
        guard error == nil, let rendered, rendered.size.width > 0, rendered.size.height > 0 else { return nil }
        let limit = display ? maximumDisplaySize : maximumInlineSize
        let scale = min(1, limit.width / rendered.size.width, limit.height / rendered.size.height)
        let size = CGSize(width: max(1, rendered.size.width * scale), height: max(1, rendered.size.height * scale))
        guard let png = png(of: rendered, size: size) else { return nil }
        let typeset = TypesetMath(png: png, width: size.width, height: size.height,
                                  descent: max(0, (layout?.descent ?? 0) * scale))
        cache.setObject(Cached(typeset), forKey: key, cost: png.count)
        return typeset
    }

    private static func png(of image: NSImage, size: CGSize) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * pixelsPerPoint).rounded(.up)),
            pixelsHigh: Int((size.height * pixelsPerPoint).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
