import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftMath

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SwiftMath's layout at reading size, rasterized only after the renderer applies its limits.
struct MathDrawing {
    let size: CGSize
    let descent: CGFloat
    let draw: (CGContext) -> Void

    func png(pixels: CGSize) -> Data? {
        let width = Int(pixels.width), height = Int(pixels.height)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: pixels.width / size.width, y: pixels.height / size.height)
        draw(context)
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    #if os(macOS)
    private static let lock = NSLock()

    static func make(_ formula: String, display: Bool) -> MathDrawing? {
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
        return MathDrawing(size: rendered.size, descent: layout?.descent ?? 0) { context in
            lock.lock()
            defer { lock.unlock() }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            rendered.draw(in: CGRect(origin: .zero, size: rendered.size))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    #else
    static func make(_ formula: String, display: Bool) -> MathDrawing? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { layout(formula, display: display) }
        }
        return DispatchQueue.main.sync { layout(formula, display: display) }
    }

    // MathImage on UIKit allocates its bitmap at intrinsic size before returning the metrics.
    // Obtain the same display list from an unattached label so even a long equation draws
    // into a bounded bitmap. Only label layout requires UIKit's main actor.
    @MainActor private static func layout(_ formula: String, display: Bool) -> MathDrawing? {
        let label = MTMathUILabel()
        label.fontSize = display ? 22 : 16
        label.font = MathFont.latinModernFont.mtfont(size: label.fontSize)
        label.latex = formula
        label.labelMode = display ? .display : .text
        label.textAlignment = display ? .center : .left
        let intrinsic = label.intrinsicContentSize
        let size = CGSize(width: ceil(intrinsic.width), height: ceil(intrinsic.height))
        guard size.width > 0, size.height > 0 else { return nil }
        label.bounds = CGRect(origin: .zero, size: size)
        label.layoutIfNeeded()
        guard let list = label.displayList else { return nil }
        return MathDrawing(size: size, descent: list.descent) { context in
            UIGraphicsPushContext(context)
            list.draw(context)
            UIGraphicsPopContext()
        }
    }
    #endif
}
