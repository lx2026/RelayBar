import MarkdownRendering
import AppKit
import CompositionFixtures
import WebKit
import XCTest
@testable import RelayBar

/// The Markdown preview in a real web view: nothing a document says can run, fetch or
/// navigate, and every click reaches the link policy.
@MainActor
final class RemoteMarkdownWebViewTests: XCTestCase {
    func testMarkupThatBypassesTheRendererRunsNothingAndRequestsNothing() async throws {
        let fixture = try await HTMLHTTPFixture(files: [
            "/probe.png": "x", "/probe.css": "p{color:red}", "/frame.html": "<p>frame</p>"
        ])
        defer { fixture.stop() }
        let base = fixture.baseURL
        // `<link rel="preconnect">` is left out: WebKit opens that connection despite the
        // content policy. The renderer never writes a link element.
        let hostile = """
            <p id="marker">hostile</p>
            <script>window.ran = 1; document.title = 'ran'</script>
            <script src="\(base)/probe.js"></script>
            <img src="\(base)/probe.png" onerror="window.ran = 2">
            <img src="data:image/png;base64,AAAA" onerror="window.ran = 3">
            <svg onload="window.ran = 4"></svg>
            <link rel="stylesheet" href="\(base)/probe.css">
            <link rel="prefetch" href="\(base)/prefetch">
            <link rel="icon" href="\(base)/icon.png">
            <style>@import url("\(base)/import.css"); body { background: url("\(base)/background.png") }
            @font-face { font-family: probe; src: url("\(base)/font.woff") } p { font-family: probe }</style>
            <p style="background: url('\(base)/inline.png')">styled</p>
            <iframe src="\(base)/frame.html"></iframe>
            <object data="\(base)/object"></object>
            <video src="\(base)/video.mp4" autoplay></video>
            <meta http-equiv="refresh" content="0;url=\(base)/refresh">
            """
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }

        view.load(body: hostile, referenceToken: "hostile")
        try await waitJS(view, "document.readyState === 'complete' && document.getElementById('marker') !== null")
        try await Task.sleep(for: .seconds(1.5))

        let ran = try await view.evaluateJavaScript("typeof window.ran") as? String
        let title = try await view.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(ran, "undefined")
        XCTAssertNotEqual(title, "ran")
        XCTAssertEqual(fixture.connectionCount, 0)
        XCTAssertEqual(view.url, URL(string: "relaybar-markdown://hostile/"))
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)

        // The same markup in an ordinary web view does reach the fixture, so the count above means something.
        let control = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = control
        control.loadHTMLString(hostile, baseURL: nil)
        try await wait("an unprotected view to reach the fixture") { fixture.connectionCount > 0 }
        control.stopLoading()
    }

    func testARenderedDocumentShowsRawHTMLAsText() async throws {
        let source = """
            <script>window.ran = 1</script>

            <img src="https://example.com/x.png" onerror="window.ran = 2">

            Some <b onclick="window.ran = 3">bold</b> text and ![remote](https://example.com/y.png).
            """
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }

        view.show(document(source, token: "rendered"))
        try await waitJS(view, "document.readyState === 'complete' && document.querySelector('article') !== null")

        let ran = try await view.evaluateJavaScript("typeof window.ran") as? String
        XCTAssertEqual(ran, "undefined")
        let innerText = try await view.evaluateJavaScript("document.body.innerText") as? String
        let text = try XCTUnwrap(innerText)
        XCTAssertTrue(text.contains("<script>window.ran = 1</script>"), text)
        XCTAssertTrue(text.contains("<b onclick=\"window.ran = 3\">"), text)
        XCTAssertTrue(text.contains("Image not loaded: remote"), text)
        let active = "document.querySelectorAll('script, iframe, object, img:not(.math), [onerror], [onclick]').length"
        let activeCount = try await view.evaluateJavaScript(active) as? Int
        XCTAssertEqual(activeCount, 0)
    }

    func testDisplayMathKeepsItsIntrinsicSizeAndFitsTheReadingColumn() async throws {
        let source = """
            $$
            \\frac{1}{2} + \\sqrt{2}
            $$

            $$
            \(Array(repeating: "x_{1} + y_{2} + z_{3}", count: 40).joined(separator: " + "))
            $$
            """
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }

        view.show(document(source, token: "math"))
        try await waitJS(view, "document.readyState === 'complete' && document.querySelectorAll('img.math').length === 2 && Array.from(document.images).every(i => i.complete)")

        let sizes = """
            Array.from(document.querySelectorAll('.math-display img.math')).map(i => {
                const box = i.getBoundingClientRect(), column = i.closest('.math-display').clientWidth;
                return [box.width, box.height, Number(i.getAttribute('width')), Number(i.getAttribute('height')), column];
            })
            """
        let result = try await view.evaluateJavaScript(sizes) as? [[Double]]
        let measured = try XCTUnwrap(result)
        XCTAssertEqual(measured.count, 2)
        let short = measured[0], long = measured[1]
        // A short formula is drawn at its own size, never enlarged.
        XCTAssertEqual(short[0], short[2], accuracy: 0.5)
        XCTAssertEqual(short[1], short[3], accuracy: 0.5)
        // A long one shrinks to the column and keeps within the display height limit.
        XCTAssertLessThan(long[0], long[2])
        XCTAssertLessThanOrEqual(long[0], long[4])
        XCTAssertLessThanOrEqual(long[1], 180.5)
    }

    func testLinkClicksReachTheLinkPolicyAndNeverNavigate() async throws {
        let source = """
            [web](https://example.com/docs) [relative](Guides/Setup.md#Install) [[Runbook]] #inbox/to-read
            [absolute](/etc/passwd) [parent](../notes.md) [script](javascript:alert(1))
            [forged](relaybar-wiki://open/another-preview/UnVuYm9vaw) and a footnote.[^1]

            [^1]: The note.
            """
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }
        let recorder = LinkRecorder(view)

        view.show(document(source, token: "links"))
        try await waitJS(view, "document.readyState === 'complete' && document.querySelectorAll('a').length >= 8")
        let start = try XCTUnwrap(view.url)
        XCTAssertEqual(start, URL(string: "relaybar-markdown://links/"))

        let expectations: [(String, SafeMarkdownLinkPolicy.Decision)] = [
            ("web", .external),
            ("relative", .internalMarkdown("Guides/Setup.md#Install")),
            ("Runbook", .wiki("Runbook")),
            ("#inbox/to-read", .tag("inbox/to-read")),
            ("absolute", .blocked),
            ("parent", .internalMarkdown("../notes.md")),
            ("forged", .blocked),
            ("\u{00B9}", .footnote("1")),
            ("script", .blocked)
        ]
        for (index, (title, expected)) in expectations.enumerated() {
            try await clickLink(titled: title, in: view)
            try await wait("a decision for \(title)") { recorder.decisions.count == index + 1 }
            XCTAssertEqual(recorder.decisions.last, expected, title)
            XCTAssertEqual(view.url, start, title)
        }
        XCTAssertEqual(recorder.opened, [URL(string: "https://example.com/docs")!])
        XCTAssertTrue(recorder.copied.isEmpty)
        // Every address in the page is one of the renderer's references; none names a server or a file.
        let foreign = try await view.evaluateJavaScript("[...document.querySelectorAll('a[href]')].filter(a => !a.getAttribute('href').startsWith('relaybar-link://link/links/')).length") as? Int
        XCTAssertEqual(foreign, 0)
        XCTAssertFalse(view.canGoBack)
    }

    func testCopyDeliversExactlyTheBlockAndIgnoresAnotherPreviewsLink() async throws {
        let source = """
            ```swift
            let first = 1
            ```

            ```
            second block
              keeps its indentation
            ```

            [forged copy](relaybar-copy://block/another-preview/MA)
            """
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }
        let recorder = LinkRecorder(view)

        view.show(document(source, token: "copy"))
        try await waitJS(view, "document.readyState === 'complete' && document.querySelectorAll('a.copy').length === 2")

        try await click("figure.code:nth-of-type(2) a.copy", in: view)
        try await wait("the second block to be copied") { recorder.copied.count == 1 }
        XCTAssertEqual(recorder.copied, ["second block\n  keeps its indentation"])
        XCTAssertTrue(recorder.decisions.isEmpty)
        // The app's own script marks the link done although the page runs none.
        try await waitJS(view, "document.querySelectorAll('a.copy')[1].classList.contains('done') && !document.querySelectorAll('a.copy')[0].classList.contains('done')")
        try await waitJS(view, "document.querySelectorAll('a.copy.done').length === 0")

        try await clickLink(titled: "forged copy", in: view)
        try await wait("the forged link to be judged") { recorder.decisions.count == 1 }
        XCTAssertEqual(recorder.decisions, [.blocked])
        XCTAssertEqual(recorder.copied.count, 1)
        XCTAssertEqual(view.url, URL(string: "relaybar-markdown://copy/"))
    }

    func testANewDocumentReplacesThePageAndTheSameOneIsNotReloaded() async throws {
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }
        let first = document("# First", token: "first")

        view.show(first)
        try await waitJS(view, "document.readyState === 'complete' && document.querySelector('h1')?.textContent === 'First'")
        _ = try await view.evaluateJavaScript("document.body.dataset.kept = 'yes'")
        view.show(first)
        try await Task.sleep(for: .milliseconds(200))
        let kept = try await view.evaluateJavaScript("document.body.dataset.kept") as? String
        XCTAssertEqual(kept, "yes")

        view.show(document("# Second", token: "second"))
        try await waitJS(view, "document.readyState === 'complete' && document.querySelector('h1')?.textContent === 'Second'")
        XCTAssertEqual(view.url, URL(string: "relaybar-markdown://second/"))
    }

    func testOnlyTheMarkdownWebViewLetsTheWindowKeepItsKeys() {
        let markdown = RemoteMarkdownWebView()
        defer { markdown.close() }
        let inner = NSView()
        markdown.addSubview(inner)

        XCTAssertFalse(RemoteHTMLFocus.ownsKeys(markdown))
        XCTAssertFalse(RemoteHTMLFocus.ownsKeys(inner))
        XCTAssertTrue(RemoteHTMLFocus.ownsKeys(WKWebView()))
        XCTAssertFalse(RemoteHTMLFocus.ownsKeys(NSView()))
    }

    func testContextMenuLosesOnlyItemsThatNavigateOrDownload() {
        let menu = NSMenu()
        for name in [
            "OpenLink", "OpenLinkInNewWindow", "DownloadLinkedFile", nil, "CopyLink", nil,
            "Copy", "LookUp", "Translate", nil, "OpenImageInNewWindow", "DownloadImage", nil,
            "Reload", "GoBack", "GoForward", "OpenFrameInNewWindow", nil, "SpeechMenu", "ShareMenu", nil
        ] {
            guard let name else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + name)
            menu.addItem(item)
        }

        RemoteMarkdownWebView.removeNavigatingItems(from: menu)

        XCTAssertEqual(
            menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
            ["Copy", "LookUp", "Translate", "-", "SpeechMenu", "ShareMenu"]
        )
    }

    func testConfigurationAllowsNoGesturesWindowsOrMagnification() {
        let view = RemoteMarkdownWebView()
        defer { view.close() }

        XCTAssertFalse(view.allowsBackForwardNavigationGestures)
        XCTAssertFalse(view.allowsMagnification)
        XCTAssertFalse(view.allowsLinkPreview)
        XCTAssertFalse(view.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        XCTAssertNil(view.configuration.urlSchemeHandler(forURLScheme: RemoteMarkdownWebView.baseScheme))
        XCTAssertNil(view.webView(
            view, createWebViewWith: WKWebViewConfiguration(), for: WKNavigationAction(), windowFeatures: WKWindowFeatures()
        ))
    }

    // MARK: - Helpers

    func testALinkIsJudgedAsWrittenNotAsWebKitWouldRepairIt() async throws {
        // A web view would turn the first into https://example.com/ and resolve the second under
        // the page's base, where the remainder looks external. Neither reaches WebKit as an address.
        let source = "[repaired](https:example.com) [disguised](/https://example.com/) [fine](https://example.com/ok)"
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }
        let recorder = LinkRecorder(view)
        view.show(document(source, token: "written"))
        try await waitJS(view, "document.readyState === 'complete' && document.querySelectorAll('a').length === 3")
        let start = try XCTUnwrap(view.url)
        let expectations: [(String, SafeMarkdownLinkPolicy.Decision)] = [("repaired", .blocked), ("disguised", .blocked), ("fine", .external)]
        for (index, (title, expected)) in expectations.enumerated() {
            try await clickLink(titled: title, in: view)
            try await wait("a decision for \(title)") { recorder.decisions.count == index + 1 }
            XCTAssertEqual(recorder.decisions.last, expected, title)
            XCTAssertEqual(view.url, start, title)
        }
        XCTAssertEqual(recorder.opened, [URL(string: "https://example.com/ok")!])
    }

    func testAnAddressThatIsNotOneOfThePagesReferencesOpensNothing() async throws {
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }
        let recorder = LinkRecorder(view)
        // Markup the renderer never writes: real addresses, a reference with another page's token,
        // and a reference past the end of this page's links.
        let body = """
            <a id="web" href="https://example.com/direct">web</a>
            <a id="mail" href="mailto:someone@example.com">mail</a>
            <a id="other" href="relaybar-link://link/another-preview/MA">other</a>
            <a id="beyond" href="relaybar-link://link/stray/OQ">beyond</a>
            <a id="known" href="relaybar-link://link/stray/MA">known</a>
            """
        view.load(body: body, referenceToken: "stray", links: ["https://example.com/known"])
        try await waitJS(view, "document.readyState === 'complete' && document.querySelectorAll('a').length === 5")
        for (index, id) in ["web", "mail", "other", "beyond"].enumerated() {
            try await click("#" + id, in: view)
            try await wait("a decision for \(id)") { recorder.decisions.count == index + 1 }
            XCTAssertEqual(recorder.decisions.last, .blocked, id)
        }
        XCTAssertTrue(recorder.opened.isEmpty)
        try await click("#known", in: view)
        try await wait("the known link") { recorder.decisions.count == 5 }
        XCTAssertEqual(recorder.opened, [URL(string: "https://example.com/known")!])
    }

    func testClickingALinkConnectsToNothing() async throws {
        let fixture = try await HTMLHTTPFixture(files: ["/page.html": "<h1>Elsewhere</h1>"])
        defer { fixture.stop() }
        let port = try XCTUnwrap(URL(string: fixture.baseURL)?.port)
        let (view, window) = makeView()
        defer { view.close(); window.contentView = nil }
        let recorder = LinkRecorder(view)
        // An allowed link, and one the policy refuses because it carries credentials. With real
        // addresses in the page, WebKit connects to the first one's server on the click itself.
        let source = "# Here\n\n[open](http://127.0.0.1:\(port)/page.html) [refused](http://user:secret@127.0.0.1:\(port)/other)"
        view.show(document(source, token: "quiet"))
        try await waitJS(view, "document.readyState === 'complete' && document.querySelectorAll('a').length === 2")
        let start = try XCTUnwrap(view.url)
        try await clickLink(titled: "open", in: view)
        try await clickLink(titled: "refused", in: view)
        try await wait("two decisions") { recorder.decisions.count == 2 }
        XCTAssertEqual(recorder.decisions, [.external, .blocked])
        XCTAssertEqual(recorder.opened, [URL(string: "http://127.0.0.1:\(port)/page.html")!])
        view.reload()
        view.reloadFromOrigin()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(fixture.connectionCount, 0, "the preview itself must not reach a server a link names")
        XCTAssertEqual(view.url, start)
        let heading = try await view.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
        XCTAssertEqual(heading, "Here")
    }

    private func makeView() -> (RemoteMarkdownWebView, NSWindow) {
        QuietWindow.prepareTestProcess()
        let view = RemoteMarkdownWebView()
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
        let window = QuietWindow(size: view.frame.size, styleMask: [.titled])
        window.contentView = view
        return (view, window)
    }

    private func document(_ source: String, token: String) -> RemoteMarkdownDocument {
        RemoteMarkdownDocument(
            referenceToken: token,
            page: MarkdownRenderer.page(source, options: .init(referenceToken: token, images: .placeholder, links: .indexed))
        )
    }

    /// Clicks with the app's own script, as a pointer click would, so the page needs none.
    private func click(_ selector: String, in view: WKWebView) async throws {
        let found = try await view.callAsyncJavaScript(
            "const link = document.querySelector(selector); if (!link) { return false; } link.click(); return true;",
            arguments: ["selector": selector],
            in: nil,
            contentWorld: .defaultClient
        ) as? Bool
        XCTAssertEqual(found, true, "No element for \(selector)")
    }

    /// Links carry references rather than addresses, so a test finds one by what it says.
    private func clickLink(titled title: String, in view: WKWebView) async throws {
        let found = try await view.callAsyncJavaScript(
            "const link = [...document.querySelectorAll('a')].find(a => a.textContent.trim() === title); if (!link) { return false; } link.click(); return true;",
            arguments: ["title": title],
            in: nil,
            contentWorld: .defaultClient
        ) as? Bool
        XCTAssertEqual(found, true, "No link titled \(title)")
    }

    private func wait(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func waitJS(_ view: WKWebView, _ condition: String) async throws {
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("WebKit condition failed: \(condition)")
    }
}

@MainActor
private final class LinkRecorder {
    var decisions: [SafeMarkdownLinkPolicy.Decision] = []
    var opened: [URL] = []
    var copied: [String] = []

    init(_ view: RemoteMarkdownWebView) {
        view.onDecision = { [unowned self] in self.decisions.append($0) }
        view.openExternal = { [unowned self] in self.opened.append($0) }
        view.copyText = { [unowned self] in self.copied.append($0) }
    }
}

/// Renders the two reference documents through the preview's own web view. Skipped unless
/// RELAYBAR_SNAPSHOT_DIR is set; `cacheDisplay` cannot capture web content, so this does not
/// share the visual harness.
@MainActor
final class RemoteMarkdownSnapshotTests: XCTestCase {
    static let ordinary = #"""
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
    """#

    static let extended = #"""
    ---
    title: Run 14 review
    tags: [sampler, review]
    status: draft
    ---

    # Beyond plain GFM

    > [!warning] Lower the CFG
    > Above 7 the lantern prompts burn out.

    A ==highlighted== phrase, a wiki link [[Run 13|previous run]], a tag #sampler/karras and a footnote.[^1]

    Inline math $\sigma_i = \sigma_{max}(1 - i/N)^{\rho}$ and a display formula:

    $$
    x_{t-1} = x_t + (\sigma_{t-1} - \sigma_t)\,\frac{x_t - \hat{x}_0}{\sigma_t}
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
    """#

    func testCaptureReferenceDocuments() async throws {
        guard let output = ProcessInfo.processInfo.environment["RELAYBAR_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RELAYBAR_SNAPSHOT_DIR to capture snapshots.")
        }
        QuietWindow.prepareTestProcess()
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let width: CGFloat = 820
        for (name, source) in [("ordinary", Self.ordinary), ("extended", Self.extended)] {
            let token = UUID().uuidString.lowercased()
            let document = RemoteMarkdownDocument(
                referenceToken: token,
                page: MarkdownRenderer.page(source, options: .init(referenceToken: token, images: .placeholder, links: .indexed))
            )
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = RemoteMarkdownWebView()
                view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                let window = QuietWindow(size: view.frame.size, styleMask: [.titled])
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                window.orderInOffscreen()
                view.show(document)
                var height: CGFloat = 0
                for _ in 0..<400 {
                    // The empty page shown before the load commits is also complete; wait for the article.
                    let script = "document.readyState === 'complete' && document.querySelector('article') && Array.from(document.images).every(i => i.complete) ? document.documentElement.scrollHeight : 0"
                    if let measured = try? await view.evaluateJavaScript(script) as? Double, measured > 0 {
                        height = measured
                        break
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertGreaterThan(height, 0, "the page did not load")
                window.setContentSize(NSSize(width: width, height: height))
                try await Task.sleep(for: .milliseconds(400))
                let snapshot = WKSnapshotConfiguration()
                snapshot.rect = CGRect(x: 0, y: 0, width: width, height: height)
                let image = try await view.takeSnapshot(configuration: snapshot)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("markdown-\(name)-\(label).png"))
                view.close()
                window.contentView = nil
                window.orderOut(nil)
            }
        }
    }
}
