// Draws the Frame "Viewfinder" app icon, writes the 1024 px master and builds
// AppIcon.icns from a temporary iconset. Run from the repository root:
//   swift Apps/Frame/Scripts/render-app-icon.swift
//
// The mark is specified in a 100 x 100 unit box laid over the icon body
// (origin at the body's top-left, y pointing down): four corner brackets and a
// centre dot. Files of 32 px or smaller use a simplified drawing with a heavier
// stroke and a larger dot, snapped to the pixel grid, and every file is drawn
// directly at its own pixel size.

import AppKit
import SwiftUI

let resources = "Apps/Frame/AppBundle/Resources"
let master = "\(resources)/AppIcon-1024.png"
let icns = "\(resources)/AppIcon.icns"
let iconsetFiles: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let bracketStroke = color(0xF8F8F6)
let dotFill = color(0xF1BD62)

struct Mark {
    var stroke: CGFloat, dotRadius: CGFloat, snap: Bool
}

// Brackets: corners 24 units from the centre, arms ending 8 units from it,
// corner radius 6. These are the same in both drawings.
let cornerOffset: CGFloat = 24, armOffset: CGFloat = 8, bracketRadius: CGFloat = 6
let regular = Mark(stroke: 6, dotRadius: 8, snap: false)
let simplified = Mark(stroke: 8, dotRadius: 10, snap: true)

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
    let fill = CGGradient(colorsSpace: nil, colors: [color(0x3B3E39), color(0x20231F)] as CFArray,
                          locations: [0, 1])!
    context.drawLinearGradient(fill, start: CGPoint(x: 0, y: body.minY),
                               end: CGPoint(x: 0, y: body.maxY), options: [])
    // Inner edge: 2 px at 1024, never thinner than one pixel, light along the
    // top half so the dark body reads on dark backgrounds, dark at the bottom.
    // The stroke is centred on the outline, so the body clip keeps its inner half.
    context.saveGState()
    context.addPath(shape)
    context.setLineWidth(2 * max(2 * px, 1))
    context.replacePathWithStrokedPath()
    context.clip()
    let edge = CGGradient(colorsSpace: nil,
                          colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0.14), color(0xFFFFFF, 0),
                                   color(0, 0), color(0, 0.25)] as CFArray,
                          locations: [0, 0.5, 0.75, 0.75, 1])!
    context.drawLinearGradient(edge, start: CGPoint(x: 0, y: body.minY),
                               end: CGPoint(x: 0, y: body.maxY), options: [])
    context.restoreGState()
    context.endTransparencyLayer()
    context.restoreGState()

    // Mark, in units of the 100 x 100 box over the body, measured from its centre.
    let mark = size <= 32 ? simplified : regular
    let unit = side / 100
    let centre = n / 2
    let width = mark.snap ? max((mark.stroke * unit).rounded(), 1) : mark.stroke * unit
    // When snapping, place stroke centre lines and cap ends so the stroke edges
    // fall on whole pixels. Offsets are taken from the centre, so the four
    // brackets stay mirror images of each other.
    func offset(_ units: CGFloat) -> CGFloat {
        let d = units * unit
        guard mark.snap else { return d }
        return Int(width) % 2 == 1 ? (d - 0.5).rounded() + 0.5 : d.rounded()
    }
    let corner = offset(cornerOffset), arm = offset(armOffset)
    for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] as [(CGFloat, CGFloat)] {
        let tip = CGPoint(x: centre + sx * corner, y: centre + sy * corner)
        context.move(to: CGPoint(x: tip.x, y: centre + sy * arm))
        context.addArc(tangent1End: tip, tangent2End: CGPoint(x: centre + sx * arm, y: tip.y),
                       radius: bracketRadius * unit)
        context.addLine(to: CGPoint(x: centre + sx * arm, y: tip.y))
    }
    context.setStrokeColor(bracketStroke)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    // The canvas centre is always a whole pixel, so the dot needs no snapping.
    let r = mark.dotRadius * unit
    context.setFillColor(dotFill)
    context.fillEllipse(in: CGRect(x: centre - r, y: centre - r, width: 2 * r, height: 2 * r))

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path); run from the repository root.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
}

let files = FileManager.default
guard files.fileExists(atPath: resources) else {
    fatalError("Cannot find \(resources); run from the repository root.")
}

write(render(1024), to: URL(fileURLWithPath: master))
print("1024\t\(master)")

let temporary = files.temporaryDirectory.appendingPathComponent("frame-app-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in iconsetFiles {
    write(render(size), to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icns, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
try? files.removeItem(at: temporary)
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print("icns\t\(icns)")
