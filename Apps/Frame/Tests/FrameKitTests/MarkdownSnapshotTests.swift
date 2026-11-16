import AppKit
import WebKit
import XCTest
@testable import FrameKit

/// Writes full-height PNGs of the two reference Markdown documents, drawn by Frame's own document
/// view in light and dark, when `FRAME_SNAPSHOT_DIR` is set; skipped otherwise.
@MainActor
final class MarkdownSnapshotTests: XCTestCase {
  func testWritesReferenceDocumentSnapshots() async throws {
    guard let path = ProcessInfo.processInfo.environment["FRAME_SNAPSHOT_DIR"], !path.isEmpty else {
      throw XCTSkip("Set FRAME_SNAPSHOT_DIR to write Markdown snapshots.")
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let folder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/markdown")
    let width: CGFloat = 820
    for name in ["ordinary", "extended"] {
      for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let renderer = DocumentRenderer()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = renderer.webView
        window.orderBack(nil)
        renderer.show(path: name + ".md", location: .local(folder))
        var height: CGFloat = 0
        for _ in 0..<400 {
          let ready = try? await renderer.webView.evaluateJavaScript("document.readyState === 'complete' && document.querySelector('article h1') !== null") as? Bool
          if ready == true, let measured = try? await renderer.webView.evaluateJavaScript("document.documentElement.scrollHeight") as? Double, measured > 0 {
            height = measured; break
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(height, 0, "\(name) did not load: \(renderer.error ?? "no error")")
        window.setContentSize(NSSize(width: width, height: height))
        try await Task.sleep(for: .milliseconds(400))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let image = try await renderer.webView.takeSnapshot(configuration: configuration)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: directory.appendingPathComponent("markdown-\(name)-\(label).png"))
        renderer.stop()
        await renderer.finishStopping()
        window.orderOut(nil)
        window.contentView = nil
      }
    }
  }
}
