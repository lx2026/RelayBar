import XCTest
@testable import MarkdownRendering

final class MarkdownRendererTests: XCTestCase {
    private let token = "0f0e0d0c-test"

    private func page(
        _ source: String,
        images: ObsidianMarkdownCompatibility.ImageHandling = .placeholder,
        enriched: Bool = true
    ) -> MarkdownPage {
        MarkdownRenderer.page(source, options: .init(referenceToken: token, images: images, enriched: enriched))
    }

    func testStructureOfAnOrdinaryDocument() {
        let page = page("# Title\n\nSome *text* and `code`.\n\n- [x] done\n- [ ] open\n- plain\n\n| A | B |\n| :-- | --: |\n| 1 | 2 |\n")
        XCTAssertTrue(page.html.hasPrefix("<article class=\"markdown\">"))
        XCTAssertTrue(page.html.contains("<h1>Title</h1>"))
        XCTAssertTrue(page.html.contains("<em>text</em>"))
        XCTAssertTrue(page.html.contains("<div class=\"table-scroll\">"))
        XCTAssertTrue(page.html.contains("<th align=\"left\">A</th>"))
        XCTAssertTrue(page.html.contains("<td align=\"right\">2</td>"))
        XCTAssertEqual(page.html.components(separatedBy: "<input type=\"checkbox\"").count - 1, 2,
                       "a plain bullet beside task items must not get a checkbox")
        XCTAssertTrue(page.html.contains("<li>plain</li>"))
        XCTAssertTrue(page.plainText.contains("Title"))
        XCTAssertTrue(page.plainText.contains("plain"))
    }

    func testCodeBlocksCarryALabelACopyLinkAndBothAppearances() throws {
        let page = page("```python\ndef f(x):\n    return x < 1\n```\n\n```\nplain <b>\n```\n\n```mermaid\ngraph LR\n```\n\n```nosuchlanguage\nabc\n```\n")
        XCTAssertEqual(page.codeBlocks, ["def f(x):\n    return x < 1", "plain <b>", "graph LR", "abc"])
        XCTAssertEqual(page.html.components(separatedBy: "<figure class=\"code\">").count - 1, 4)
        XCTAssertTrue(page.html.contains("<span class=\"language\">python</span>"))
        XCTAssertTrue(page.html.contains("<span class=\"language\">plain text</span>"))
        XCTAssertTrue(page.html.contains("<pre class=\"light\"><code>"))
        XCTAssertTrue(page.html.contains("<pre class=\"dark\"><code>"))
        XCTAssertTrue(page.html.contains("<span style=\"color:#"), "a known language is highlighted")
        XCTAssertTrue(page.html.contains("<pre><code>plain &lt;b&gt;</code></pre>"), "unlabelled code stays plain and escaped")
        XCTAssertTrue(page.html.contains("Mermaid code is not executed"))
        XCTAssertTrue(page.html.contains("<pre><code>abc</code></pre>"), "an unknown language is shown plain")
        XCTAssertTrue(page.html.contains("x &lt; 1") || page.html.contains("&lt;"), "highlighted code is escaped")

        let links = try XCTUnwrap(NSRegularExpression(pattern: "href=\"(relaybar-copy://[^\"]+)\""))
        let matches = links.matches(in: page.html, range: NSRange(page.html.startIndex..., in: page.html))
        XCTAssertEqual(matches.count, 4)
        for (index, match) in matches.enumerated() {
            let url = try XCTUnwrap(URL(string: String(page.html[try XCTUnwrap(Range(match.range(at: 1), in: page.html))])))
            XCTAssertEqual(MarkdownRenderer.copiedBlockIndex(from: url, referenceToken: token), index)
            XCTAssertNil(MarkdownRenderer.copiedBlockIndex(from: url, referenceToken: "another-preview"))
        }
        XCTAssertNil(MarkdownRenderer.copiedBlockIndex(
            from: try XCTUnwrap(URL(string: "relaybar-copy://block/\(token)/not-base64!")), referenceToken: token))
    }

    func testNothingADocumentWritesBecomesActiveMarkup() {
        let hostile = """
        <script>alert(1)</script>

        <style>body{display:none}</style>

        Inline <img src=x onerror=alert(1)> and <iframe src="https://example.com"></iframe> and <a href="javascript:alert(1)">x</a>.

        [link](javascript:alert(1)) [data](data:text/html,<script>alert(1)</script>) [file](file:///etc/passwd)

        ![remote](https://example.com/a.png) ![inline](data:image/png;base64,AAAA)

        <details><summary>More</summary>
        Hidden text
        </details>
        """
        for enriched in [true, false] {
            let html = page(hostile, enriched: enriched).html.lowercased()
            for tag in ["<script", "<style", "<iframe", "<img", "<details", "<summary", "<a href=\"javascript", "<object", "<embed"] {
                XCTAssertFalse(html.contains(tag), "\(tag) reached the page (enriched: \(enriched))")
            }
            XCTAssertFalse(html.contains("href=\"javascript:"))
            XCTAssertFalse(html.contains("href=\"data:"))
            XCTAssertFalse(html.contains("href=\"file:"))
            XCTAssertFalse(html.contains("src=\"https://example.com"))
            XCTAssertTrue(html.contains("image not loaded"))
        }
        let enriched = page(hostile).html
        XCTAssertTrue(enriched.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), "raw HTML stays readable as text")
        XCTAssertTrue(enriched.contains("Hidden text"), "an HTML block's text is not dropped")
    }

    func testImagesPassThroughOnlyWhenTheHostAsks() {
        let source = "![Chart](chart.png) and ![Online](https://example.com/a.png)"
        let shown = page(source, images: .passthrough).html
        XCTAssertTrue(shown.contains("<img src=\"chart.png\" alt=\"Chart\""))
        XCTAssertTrue(shown.contains("<img src=\"https://example.com/a.png\" alt=\"Online\""))
        let hidden = page(source).html
        XCTAssertFalse(hidden.contains("<img"))
        XCTAssertTrue(hidden.contains("Image not loaded:"))
        XCTAssertTrue(hidden.contains("Chart"))
        XCTAssertFalse(page("![x](javascript:alert(1))", images: .passthrough).html.contains("javascript:"))
    }

    func testAnImageInsideAnotherImagesLabelIsHandledOnce() {
        let nested = "![outer ![inner](a.png) text](b.png) and [![badge](c.png)](https://example.com)"
        for enriched in [true, false] {
            let hidden = page(nested, enriched: enriched).html
            XCTAssertFalse(hidden.contains("<img"), "enriched: \(enriched)")
            XCTAssertTrue(hidden.contains("Image not loaded:"))
            let shown = page(nested, images: .passthrough, enriched: enriched).html
            XCTAssertTrue(shown.contains("src=\"b.png\""), "enriched: \(enriched)")
            XCTAssertTrue(shown.contains("src=\"c.png\""))
        }
    }

    func testImagesAndMathInsideTableCellsAreStillReplaced() {
        let table = "| H | M |\n| --- | --- |\n| ![x](https://example.com/x.png) | $a^2$ |\n"
        for enriched in [true, false] {
            let html = page(table, enriched: enriched).html
            XCTAssertFalse(html.contains("example.com/x.png"), "enriched: \(enriched)")
            XCTAssertTrue(html.contains("Image not loaded:"), "enriched: \(enriched)")
            XCTAssertFalse(html.contains("relaybar-math://"))
        }
        let typeset = page(table).html
        XCTAssertTrue(typeset.contains("<em><img class=\"math\""), "a cell takes the formula inside an emphasis wrapper")
        let forged = "| H |\n| --- |\n| ![Math formula](relaybar-math://inline/another-preview/eA) |\n"
        for images in [ObsidianMarkdownCompatibility.ImageHandling.placeholder, .passthrough] {
            for enriched in [true, false] {
                let html = page(forged, images: images, enriched: enriched).html
                XCTAssertFalse(html.contains("relaybar-math://"), "\(images) enriched: \(enriched)")
                XCTAssertFalse(html.contains("<img"), "\(images) enriched: \(enriched)")
            }
        }
    }

    func testNoLinkCarriesContentInItsAddress() {
        let source = "[png](data:image/png;base64,AAAA) [gif](DATA:image/gif;base64,AAAA) [html](data:text/html,x) [ok](https://example.com/a)"
        for images in [ObsidianMarkdownCompatibility.ImageHandling.placeholder, .passthrough] {
            for enriched in [true, false] {
                let html = page(source, images: images, enriched: enriched).html.lowercased()
                XCTAssertFalse(html.contains("href=\"data:"), "\(images) enriched: \(enriched)")
                XCTAssertTrue(html.contains("href=\"https://example.com/a\""))
            }
        }
    }

    func testIndexedLinksLeaveNoAddressInThePage() throws {
        let source = "[web](https://example.com/docs?a=1&b=2) <https://auto.example.com> [rel](../notes.md) [[Wiki]] #tag [bad](javascript:alert(1)) [data](data:text/html,x) [mail](mailto:a@example.com)"
        let page = MarkdownRenderer.page(source, options: .init(referenceToken: token, links: .indexed))
        let html = page.html.lowercased()
        for address in ["https://", "http://", "mailto:", "example.com", "notes.md", "relaybar-wiki:", "relaybar-tag:", "javascript:", "href=\"data:"] {
            XCTAssertFalse(html.contains("href=\"" + address) || (address == "example.com" && html.contains("href=\"https://example.com")), address)
        }
        XCTAssertEqual(page.links.count, 8)
        XCTAssertEqual(page.links[0], "https://example.com/docs?a=1&b=2")
        XCTAssertEqual(page.links[1], "https://auto.example.com")
        XCTAssertEqual(page.links[2], "../notes.md")
        XCTAssertTrue(page.links[3].hasPrefix("relaybar-wiki://"))
        XCTAssertTrue(page.links[4].hasPrefix("relaybar-tag://"))
        XCTAssertEqual(page.links[5], "javascript:alert(1)", "the host's policy sees and refuses it")
        XCTAssertEqual(page.links[7], "mailto:a@example.com")
        let references = try XCTUnwrap(NSRegularExpression(pattern: "href=\"(relaybar-link://[^\"]+)\""))
        let matches = references.matches(in: page.html, range: NSRange(page.html.startIndex..., in: page.html))
        XCTAssertEqual(matches.count, 8)
        XCTAssertEqual(page.html.components(separatedBy: "href=\"").count - 1, 8, "every address in the page is a reference")
        for (index, match) in matches.enumerated() {
            let url = try XCTUnwrap(URL(string: String(page.html[try XCTUnwrap(Range(match.range(at: 1), in: page.html))])))
            XCTAssertEqual(MarkdownRenderer.linkedIndex(from: url, referenceToken: token), index)
            XCTAssertNil(MarkdownRenderer.linkedIndex(from: url, referenceToken: "another-preview"))
            XCTAssertNil(MarkdownRenderer.copiedBlockIndex(from: url, referenceToken: token))
        }
        XCTAssertTrue(MarkdownRenderer.page(source, options: .init(referenceToken: token)).links.isEmpty)
    }

    func testADeeplyNestedImageLabelIsReadWithoutRecursion() {
        let stars = String(repeating: "*", count: 100_000)
        let html = page("![" + stars + "x" + stars + "](x.png)", enriched: false).html
        XCTAssertTrue(html.contains("Image not loaded:"))
        XCTAssertFalse(html.contains("<img"))
    }

    func testALongRunOfBackslashesDoesNotMakeTheScanQuadratic() {
        // Without a bound on the escape check this is tens of billions of steps and never returns.
        let run = String(repeating: "\\", count: 300_000)
        XCTAssertFalse(page("[r]: " + run + "x\n\ntext [r]\n").html.isEmpty)
        XCTAssertFalse(page("a " + String(repeating: "\\", count: 60_000) + "<script>x</script>\n").html.contains("<script"))
    }

    func testTheDefaultTokenCannotBeGuessed() {
        XCTAssertNotEqual(MarkdownRenderOptions().referenceToken, MarkdownRenderOptions().referenceToken)
        let forged = "![Math formula](relaybar-math://inline/standalone/eA)"
        XCTAssertFalse(MarkdownRenderer.page(forged, options: .init(images: .passthrough)).html.contains("<img"))
        XCTAssertFalse(MarkdownRenderer.page(forged).html.contains("<img"))
        for value in ["LTE", "OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5", "MS41", ""] {
            let url = URL(string: "relaybar-copy://block/\(token)/\(value)")
            XCTAssertNil(url.flatMap { MarkdownRenderer.copiedBlockIndex(from: $0, referenceToken: token) }, value)
        }
    }

    func testAFenceLabelCannotBreakOutOfTheFigure() {
        let html = page("```\"><script>x</script>&amp;\ncode </code></pre><script>y</script>\n```\n").html
        XCTAssertFalse(html.contains("<script"))
        XCTAssertTrue(html.contains("&lt;script&gt;x&lt;/script&gt;"))
        XCTAssertTrue(html.contains("code &lt;/code&gt;&lt;/pre&gt;&lt;script&gt;y&lt;/script&gt;"))
        XCTAssertEqual(html.components(separatedBy: "<figure class=\"code\">").count - 1, 1)
    }

    func testMathBecomesAnImageAndFallsBackToItsSource() {
        let page = page("Inline $x^2 + y_1$ here.\n\n$$\n\\frac{a}{b}\n$$\n\nBroken $\\frac{a$ stays.\n")
        XCTAssertEqual(page.html.components(separatedBy: "<img class=\"math\"").count - 1, 2)
        XCTAssertTrue(page.html.contains("alt=\"Math formula: x^2 + y_1\""))
        XCTAssertTrue(page.html.contains("src=\"data:image/png;base64,"))
        XCTAssertTrue(page.html.contains("<span class=\"math-display\"><img class=\"math\""))
        XCTAssertTrue(page.html.contains("style=\"vertical-align:-"), "inline math sits on the baseline")
        XCTAssertTrue(page.html.contains("\\frac{a$"), "a formula that does not parse remains as written")
        XCTAssertFalse(page.html.contains("relaybar-math://"), "no math link is left for the page to request")
    }

    func testAMathLinkTheDocumentWroteItselfIsNotTypeset() {
        let forged = "![Math formula](relaybar-math://inline/another-preview/eF4y)"
        for images in [ObsidianMarkdownCompatibility.ImageHandling.placeholder, .passthrough] {
            let html = page(forged, images: images).html
            XCTAssertFalse(html.contains("<img"), "forged math link rendered with images \(images)")
            XCTAssertFalse(html.contains("relaybar-math://"))
        }
    }

    func testObsidianSyntaxSurvivesIntoThePage() {
        let page = page("---\ntitle: Run\n---\n\n> [!warning] Careful\n> Body\n\nA ==mark==, [[Note|alias]], #tag/sub and a note.[^1]\n\n[^1]: The note.\n")
        XCTAssertTrue(page.html.contains("<blockquote>"))
        XCTAssertTrue(page.html.contains("Properties"))
        XCTAssertTrue(page.html.contains("Careful"))
        XCTAssertTrue(page.html.contains("href=\"relaybar-wiki://"))
        XCTAssertTrue(page.html.contains("href=\"relaybar-tag://"))
        XCTAssertTrue(page.html.contains("Footnotes"))
        XCTAssertFalse(page.html.contains("=="))
        XCTAssertFalse(page.html.contains("[!warning]"))
    }

    func testAnUnenrichedPageIsPlainButStillSafe() {
        let page = page("---\ntitle: Run\n---\n\n```swift\nlet a = 1\n```\n\n$x$ [[Note]]\n", enriched: false)
        XCTAssertFalse(page.html.contains("Properties"))
        XCTAssertFalse(page.html.contains("<pre class=\"light\">"))
        XCTAssertTrue(page.html.contains("<pre><code>let a = 1</code></pre>"))
        XCTAssertFalse(page.html.contains("<img"))
        XCTAssertEqual(page.codeBlocks, ["let a = 1"])
    }

    func testACancelledRenderProducesNothing() async {
        let task = Task.detached { () -> MarkdownPage in
            while !Task.isCancelled { await Task.yield() }
            return MarkdownRenderer.page("# Secret\n\n<script>x</script>", options: .init())
        }
        task.cancel()
        let page = await task.value
        XCTAssertEqual(page, .empty)
    }

    func testTheStylesheetCannotCloseItsOwnElement() {
        XCTAssertFalse(MarkdownRenderer.stylesheet.lowercased().contains("</style"))
        XCTAssertTrue(MarkdownRenderer.body(.empty, palette: ":root{--md-bg:#000}").hasPrefix("<style>"))
        XCTAssertTrue(MarkdownRenderer.body(.empty).hasSuffix("<article class=\"markdown\"></article>"))
    }
}
