import Foundation
import ImageIO
import XCTest
@testable import MarkdownRendering

final class ReferenceOutputTests: XCTestCase {
    func testReferenceDocumentsMatchMacRendering() throws {
        for (name, source) in [("ordinary", MarkdownSnapshotTests.ordinary), ("extended", MarkdownSnapshotTests.extended)] {
            let page = MarkdownRenderer.page(source, options: .init(referenceToken: "snapshot"))
            let reference = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "ReferencePages"))
            let expected = try splitPage(String(contentsOf: reference, encoding: .utf8))
            let actual = try splitPage(page.html)
            XCTAssertEqual(actual.html, expected.html, name)
            XCTAssertEqual(actual.images.count, expected.images.count, name)
            for (image, original) in zip(actual.images, expected.images) {
                XCTAssertEqual(image.width, original.width)
                XCTAssertEqual(image.height, original.height)
                let pixels = try coverage(image), referencePixels = try coverage(original)
                guard pixels.count == referencePixels.count else { continue }
                let error = zip(pixels, referencePixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                let ink = referencePixels.reduce(0) { $0 + Int($1) }
                XCTAssertGreaterThan(ink, 0)
                // Core Text rasterization varies across OS releases even at identical layout metrics.
                #if os(macOS)
                let maximumRelativeError = 0.01
                #else
                let maximumRelativeError = 0.025
                #endif
                XCTAssertLessThan(Double(error) / Double(ink), maximumRelativeError, "\(name) equation \(image.width)×\(image.height)")
            }
        }
    }

    // Compare the markup, including size and baseline, independently of PNG compression and metadata.
    private func splitPage(_ input: String) throws -> (html: String, images: [CGImage]) {
        var html = input
        var images: [CGImage] = []
        let pattern = try NSRegularExpression(pattern: #"data:image/png;base64,([\w+/=]+)"#)
        for match in pattern.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            let encoded = (input as NSString).substring(with: match.range(at: 1))
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            images.append(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
            html.replaceSubrange(try XCTUnwrap(Range(match.range, in: html)), with: "png")
        }
        return (html, images)
    }

    private func coverage(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.draw(image, in: bounds)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return UnsafeBufferPointer(start: bytes, count: image.width * image.height).map { 255 - $0 }
    }
}
