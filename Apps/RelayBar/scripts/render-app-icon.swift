// Draws the RelayBar "Route" app icon and writes every PNG in the asset catalog
// plus the 1024 px master. Run from the repository root:
//   swift Apps/RelayBar/scripts/render-app-icon.swift
//
// The mark is specified in a 100 x 100 unit box laid over the icon body
// (origin at the body's top-left, y pointing down). Files of 32 px or smaller
// use a simplified drawing with heavier strokes and no vertical bar, and every
// file is drawn directly at its own pixel size.

import AppKit
import SwiftUI

let iconSet = "Apps/RelayBar/Assets.xcassets/AppIcon.appiconset"
let outputs: [(path: String, size: Int)] = [
    ("\(iconSet)/icon_16x16.png", 16),
    ("\(iconSet)/icon_16x16@2x.png", 32),
    ("\(iconSet)/icon_32x32.png", 32),
    ("\(iconSet)/icon_32x32@2x.png", 64),
    ("\(iconSet)/icon_128x128.png", 128),
    ("\(iconSet)/icon_128x128@2x.png", 256),
    ("\(iconSet)/icon_256x256.png", 256),
    ("\(iconSet)/icon_256x256@2x.png", 512),
    ("\(iconSet)/icon_512x512.png", 512),
    ("\(iconSet)/icon_512x512@2x.png", 1024),
    ("Apps/RelayBar/Assets/RelayBar-AppIcon-1024.png", 1024),
]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let blue = color(0x1463E6)
let nodeFill = color(0xF6F7FA)
let barFill = color(0xD3D8E3)

struct Mark {
    var bar: Bool
    var routeLow: CGFloat, routeHigh: CGFloat, routeWidth: CGFloat
    var start: CGPoint, startRadius: CGFloat, startStroke: CGFloat
    var end: CGPoint, endRadius: CGFloat
}

let regular = Mark(bar: true, routeLow: 65, routeHigh: 35, routeWidth: 6,
                   start: CGPoint(x: 31, y: 65), startRadius: 6, startStroke: 6,
                   end: CGPoint(x: 69, y: 35), endRadius: 8.5)
let simplified = Mark(bar: false, routeLow: 66, routeHigh: 34, routeWidth: 8,
                      start: CGPoint(x: 30, y: 66), startRadius: 7.5, startStroke: 7,
                      end: CGPoint(x: 70, y: 34), endRadius: 11)

func render(_ size: Int) -> CGImage {
    let n = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: n)
    context.scaleBy(x: 1, y: -1)

    // Body: 824/1024 of the canvas, rounded to an even pixel count so its
    // edges fall on whole pixels; 14 of 16 px so the smallest mark stays legible.
    let side = size == 16 ? 14 : 2 * (n * 412 / 1024).rounded()
    let inset = (n - side) / 2
    let body = CGRect(x: inset, y: inset, width: side, height: side)
    let shape = RoundedRectangle(cornerRadius: side * 185.4 / 824, style: .continuous)
        .path(in: body).cgPath
    let px = n / 1024

    // Shadow offsets are in device space, where y points up.
    context.saveGState()
    switch size {
    case ...16: break
    case ...32: context.setShadow(offset: CGSize(width: 0, height: -1), blur: 0.5, color: color(0, 0.18))
    default: context.setShadow(offset: CGSize(width: 0, height: -12 * px), blur: 22 * px, color: color(0, 0.28))
    }
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF), color(0xE4E8EF)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY),
                               end: CGPoint(x: 0, y: body.maxY), options: [])
    // Inner edge: 2 px at 1024, never thinner than one pixel. The stroke is
    // centred on the outline, so the clip keeps only its inner half.
    context.addPath(shape)
    context.setLineWidth(2 * max(2 * px, 1))
    context.setStrokeColor(color(0, 0.07))
    context.strokePath()
    context.endTransparencyLayer()
    context.restoreGState()

    // Mark, in units of the 100 x 100 box over the body.
    let mark = size <= 32 ? simplified : regular
    let unit = side / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: inset + x * unit, y: inset + y * unit) }
    // At 32 px and below, centre a feature `width` units wide so it covers whole pixels.
    func align(_ v: CGFloat, _ width: CGFloat) -> CGFloat {
        guard size <= 32 else { return v }
        return Int((width * unit).rounded()) % 2 == 1 ? (v - 0.5).rounded() + 0.5 : v.rounded()
    }
    func circle(_ c: CGPoint, _ r: CGFloat, outer: CGFloat) -> CGRect {
        let center = p(c.x, c.y)
        let x = align(center.x, 2 * outer), y = align(center.y, 2 * outer)
        return CGRect(x: x - r * unit, y: y - r * unit, width: 2 * r * unit, height: 2 * r * unit)
    }

    if mark.bar {
        let bar = CGRect(origin: p(47, 22), size: CGSize(width: 6 * unit, height: 56 * unit))
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 3 * unit, cornerHeight: 3 * unit, transform: nil))
        context.setFillColor(barFill)
        context.fillPath()
    }

    let low = align(p(0, mark.routeLow).y, mark.routeWidth)
    let high = align(p(0, mark.routeHigh).y, mark.routeWidth)
    func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: p(x, 0).x, y: y) }
    context.move(to: q(33, low))
    context.addLine(to: q(40, low))
    context.addCurve(to: q(60, high), control1: q(52, low), control2: q(48, high))
    context.addLine(to: q(67, high))
    context.setStrokeColor(blue)
    context.setLineWidth(mark.routeWidth * unit)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    let start = circle(mark.start, mark.startRadius, outer: mark.startRadius + mark.startStroke / 2)
    context.setFillColor(nodeFill)
    context.fillEllipse(in: start)
    context.setLineWidth(mark.startStroke * unit)
    context.strokeEllipse(in: start)

    context.setFillColor(blue)
    context.fillEllipse(in: circle(mark.end, mark.endRadius, outer: mark.endRadius))

    return context.makeImage()!
}

for (path, size) in outputs {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Cannot write \(path); run from the repository root.")
    }
    CGImageDestinationAddImage(destination, render(size), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(path)") }
    print("\(size)\t\(path)")
}
