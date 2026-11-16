import AppKit
import WebKit
import XCTest
@testable import MarkdownRendering

/// Renders the two reference documents offscreen in a real web view. Skipped unless
/// MARKDOWN_SNAPSHOT_DIR is set; MARKDOWN_SNAPSHOT_SOURCES may name a folder of other
/// `.md` files to render instead, and MARKDOWN_SNAPSHOT_PALETTE a CSS override.
/// A window taller than the screen, so a whole document fits in one snapshot.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class MarkdownSnapshotTests: XCTestCase {
    static let ordinary = """
    # Sampler run 14 — notes

    A *short* report with **bold**, ~~struck~~ text, `inline code`, a [link](https://example.com) and a bare URL: https://example.com/runs/14.

    ## Checklist

    - [x] Seeds fixed for all eight prompts
    - [ ] Re-run the two failures
      - [ ] `cfg 7.5`, 30 steps
      - [x] `cfg 5.0`, 40 steps
    - Plain item with a nested list
      1. first
      2. second

    ## Results

    | Prompt | Steps | CFG | Seed | Verdict |
    | :-- | --: | --: | --: | :-- |
    | harbour at dusk | 30 | 7.5 | 1184 | keep |
    | paper lantern, macro | 40 | 5.0 | 2291 | redo — hands |
    | long-column table to test width, with a much longer description cell | 30 | 7.5 | 77 | keep |

    ## Code

    ```python
    def schedule(steps: int, sigma_max: float = 14.6) -> list[float]:
        # Karras-style spacing
        return [sigma_max * (1 - i / steps) ** 7 for i in range(steps)]
    ```

    ```
    no language given: plain block with a long line that should scroll rather than wrap ............................................
    ```

    > Quoted remark: the lantern set needs a lower CFG.
    > It continues on a second line.

    ![Colour bands from the run](diagram.png)

    ---

    Final paragraph after a rule.
    """

    static let extended = """
    ---
    title: Run 14 review
    tags: [sampler, review]
    status: draft
    ---

    # Beyond plain GFM

    > [!warning] Lower the CFG
    > Above 7 the lantern prompts burn out.

    A ==highlighted== phrase, a wiki link [[Run 13|previous run]], a tag #sampler/karras and a footnote.[^1]

    Inline math $\\sigma_i = \\sigma_{max}(1 - i/N)^{\\rho}$ and a display formula:

    $$
    x_{t-1} = x_t + (\\sigma_{t-1} - \\sigma_t)\\,\\frac{x_t - \\hat{x}_0}{\\sigma_t}
    $$

    - [/] Half-done Obsidian task
    - [x] Done task

    Raw HTML: press <kbd>⌘</kbd><kbd>F</kbd>, and a <span style="color:red">red span</span>.

    <details><summary>Collapsed detail</summary>
    Hidden until opened.
    </details>

    <script>document.title = "ran"</script>

    ```mermaid
    graph LR
      A[Prompt] --> B[Sampler] --> C[Image]
    ```

    ```swift
    struct Run: Codable { let seed: Int; var keep = false }
    ```

    [^1]: Footnote text with a second sentence.
    """

    /// Times the renderer and a web view's layout for each `.md` file in MARKDOWN_PERF_SOURCES,
    /// appending one line per file to MARKDOWN_PERF_OUT. Skipped unless both are set.
    @MainActor func testMeasureRenderAndLayout() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sources = environment["MARKDOWN_PERF_SOURCES"], let output = environment["MARKDOWN_PERF_OUT"] else {
            throw XCTSkip("Set MARKDOWN_PERF_SOURCES and MARKDOWN_PERF_OUT to measure.")
        }
        _ = NSApplication.shared
        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> String {
            String(format: "%.0fms", (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1_000)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 700), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        func load(_ html: String, marker: String) async throws -> Double {
            view.loadHTMLString("<!doctype html><meta charset=\"utf-8\">" + html, baseURL: nil)
            for _ in 0..<20_000 {
                let ready = "document.readyState === 'complete' && document.body.dataset.marker === '\(marker)' ? document.documentElement.scrollHeight : 0"
                if let height = try? await view.evaluateJavaScript(ready) as? Double, height > 0 { return height }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            XCTFail("the page did not load"); return 0
        }
        // The first load also starts the web content process; keep it out of the figures.
        _ = try await load("<body data-marker=\"warm\">warm</body>", marker: "warm")
        var lines = ""
        for name in try FileManager.default.contentsOfDirectory(atPath: sources).filter({ $0.hasSuffix(".md") }).sorted() {
            let source = try String(contentsOfFile: sources + "/" + name, encoding: .utf8)
            for pass in ["first", "again"] {
                let start = clock.now
                let page = await Task.detached { MarkdownRenderer.page(source, options: .init(referenceToken: "perf")) }.value
                let rendered = clock.now
                let height = try await load("<body data-marker=\"\(name)\(pass)\">" + MarkdownRenderer.body(page), marker: name + pass)
                let laidOut = clock.now
                lines += "\(name) \(pass) render=\(milliseconds(rendered - start)) layout=\(milliseconds(laidOut - rendered)) total=\(milliseconds(laidOut - start)) htmlBytes=\(page.html.utf8.count) contentHeight=\(Int(height))\n"
            }
        }
        let url = URL(fileURLWithPath: output)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try Data((existing + lines).utf8).write(to: url)
        window.contentView = nil
    }

    @MainActor func testCaptureReferenceDocuments() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["MARKDOWN_SNAPSHOT_DIR"] else { throw XCTSkip("Set MARKDOWN_SNAPSHOT_DIR to capture snapshots.") }
        _ = NSApplication.shared
        var documents = [("ordinary", Self.ordinary), ("extended", Self.extended)]
        if let sources = environment["MARKDOWN_SNAPSHOT_SOURCES"] {
            documents = try FileManager.default.contentsOfDirectory(atPath: sources).filter { $0.hasSuffix(".md") }.sorted().map {
                (($0 as NSString).deletingPathExtension, try String(contentsOfFile: sources + "/" + $0, encoding: .utf8))
            }
        }
        let palette = environment["MARKDOWN_SNAPSHOT_PALETTE"] ?? ""
        let width: CGFloat = 820
        for (name, source) in documents {
            let page = MarkdownRenderer.page(source, options: .init(referenceToken: "snapshot"))
            let html = "<!doctype html><meta charset=\"utf-8\">" + MarkdownRenderer.body(page, palette: palette)
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.defaultWebpagePreferences.allowsContentJavaScript = false
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900), configuration: configuration)
                let window = UnconstrainedWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                window.orderBack(nil)
                view.loadHTMLString(html, baseURL: nil)
                var height: CGFloat = 0
                for _ in 0..<400 {
                    if let measured = try? await view.evaluateJavaScript("document.readyState === 'complete' && document.querySelector('article') ? document.documentElement.scrollHeight : 0") as? Double, measured > 0 {
                        height = measured; break
                    }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                XCTAssertGreaterThan(height, 0, "the page did not load")
                window.setContentSize(NSSize(width: width, height: height))
                try await Task.sleep(nanoseconds: 400_000_000)
                let snapshot = WKSnapshotConfiguration()
                snapshot.rect = CGRect(x: 0, y: 0, width: width, height: height)
                let image = try await view.takeSnapshot(configuration: snapshot)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name)-\(label).png"))
                window.contentView = nil
            }
        }
    }
}
