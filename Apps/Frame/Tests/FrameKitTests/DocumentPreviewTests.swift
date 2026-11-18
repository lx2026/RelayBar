import BridgeProtocol
import AppKit
import MarkdownRendering
import SwiftData
import WebKit
import XCTest
@testable import FrameKit

final class DocumentPreviewTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FrameDocuments-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func testDocumentsArePrimaryAndDependenciesAreNotOwned() throws {
    let root = try root()
    for name in ["result.png", "result.md", "result.html", "result.prompt.json", "result.qqq.txt", "style.css"] {
      try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
    }
    let scan = try FileScanner.directory(rootURL: root, rootID: UUID(), path: "")
    XCTAssertEqual(Set(scan.photos.map(\.name)), ["result.png", "result.md", "result.html"])
    XCTAssertEqual(scan.files.count, 6)
    XCTAssertEqual(scan.photos.first { $0.name == "result.png" }?.companions.map { $0.url.lastPathComponent }, ["result.prompt.json", "result.qqq.txt"])
    XCTAssertTrue(scan.photos.filter { $0.format.isDocument }.allSatisfy { $0.companions.isEmpty })
    XCTAssertNotNil(scan.files.first { $0.name == "result.qqq.txt" }?.companionOwnerID)
    let document = try XCTUnwrap(scan.photos.first { $0.name == "result.html" })
    _ = try ArchiveService.archive(document, root: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("style.css").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("result.md").path))
  }
  @MainActor func testMarkdownAndBoundedText() throws {
    let html = DocumentHTML.markdown("# Heading\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n- [x] Done\n\n```swift\nlet x = 1\n```\n\n![Photo](images/a.png)\n\n<script>alert(1)</script>", referenceToken: "frame-test")
    for token in ["<h1>", "<table>", "type=\"checkbox\"", "<span class=\"language\">swift</span>", "<img src=\"images/a.png\"", "href=\"relaybar-copy://block/frame-test/"] {
      XCTAssertTrue(html.contains(token), token)
    }
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertTrue(html.hasPrefix("<style>" + MarkdownRenderer.stylesheet + DocumentHTML.palette + "</style><article class=\"markdown\">"))
    XCTAssertEqual(DocumentHTML.theme, MarkdownRenderer.stylesheet + DocumentHTML.palette)
    let text = try DocumentHTML.page(Data("a < b & c".utf8), extension: "txt", referenceToken: "frame-test")
    XCTAssertEqual(text, "<style>\(DocumentHTML.theme)</style><article><pre>a &lt; b &amp; c</pre></article>")
    XCTAssertEqual(try DocumentHTML.page(Data("<p onclick='x()'>kept</p>".utf8), extension: "HTML", referenceToken: "frame-test"), "<p onclick='x()'>kept</p>")
    XCTAssertThrowsError(try DocumentHTML.page(Data([0, 1, 2]), extension: "bin", referenceToken: "frame-test"))
    XCTAssertThrowsError(try DocumentHTML.page(Data(repeating: 65, count: DocumentResources.documentLimit + 1), extension: "md", referenceToken: "frame-test"))
  }
  @MainActor func testMarkdownAboveTwoMebibytesSkipsEnrichmentAndStaysSafe() throws {
    let head = "---\ntitle: Large\n---\n\n# Large\n\n```swift\nlet a = 1\n```\n\n<script>window.ran = true</script>\n\n<img src=\"x\" onerror=\"window.ran = true\">\n\n"
    let small = try DocumentHTML.page(Data(head.utf8), extension: "md", referenceToken: "frame-test")
    XCTAssertTrue(small.contains("Properties"), "a small document keeps the Obsidian pass")
    XCTAssertTrue(small.contains("<pre class=\"light\">"))
    let source = head + String(repeating: String(repeating: "filler ", count: 150) + "\n\n", count: MarkdownRenderer.maximumEnrichedByteCount / 1_050 + 1)
    XCTAssertGreaterThan(source.utf8.count, MarkdownRenderer.maximumEnrichedByteCount)
    let large = try DocumentHTML.page(Data(source.utf8), extension: "md", referenceToken: "frame-test")
    XCTAssertFalse(large.contains("Properties"))
    XCTAssertFalse(large.contains("<pre class=\"light\">"))
    XCTAssertTrue(large.contains("<pre><code>let a = 1</code></pre>"))
    XCTAssertTrue(large.contains("href=\"relaybar-copy://block/frame-test/"))
    for tag in ["<script", "<img", "onerror="] { XCTAssertFalse(large.lowercased().contains(tag), tag) }
    XCTAssertTrue(large.contains(DocumentHTML.palette))
  }
  func testLocalResourcesContainmentRevalidationAndAtomicReplacement() async throws {
    let root = try root(), outside = try self.root()
    try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let source = DocumentResources(location: .local(root))
    for path in ["../secret.txt", "escape/secret.txt", "missing", "a/../../secret.txt"] {
      do { _ = try await source.data(at: path); XCTFail("Read \(path)") } catch {}
    }
    let file = root.appendingPathComponent("notes.md")
    try Data("first".utf8).write(to: file)
    let first = try await source.data(at: "notes.md")
    XCTAssertEqual(String(data: first, encoding: .utf8), "first")
    try Data("second".utf8).write(to: file, options: .atomic)
    let changed = try await source.refresh()
    XCTAssertTrue(changed)
    let second = try await source.data(at: "notes.md")
    XCTAssertEqual(String(data: second, encoding: .utf8), "second")
    try Data("third".utf8).write(to: file, options: .atomic)
    try await source.begin()
    let third = try await source.data(at: "notes.md")
    XCTAssertEqual(String(data: third, encoding: .utf8), "third")
  }
  func testLocalResourcesSplitAtEverySlashEvenOneACombiningMarkFollows() async throws {
    // A slash followed by a combining mark is one Swift character but two components to the file system.
    let base = try root(), root = base.appendingPathComponent("library"), outside = base.appendingPathComponent("outside")
    for folder in [root, outside, root.appendingPathComponent("docs")] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let hidden = "\u{301}secret.txt"
    try Data("secret".utf8).write(to: outside.appendingPathComponent(hidden))
    try Data("secret".utf8).write(to: base.appendingPathComponent(hidden))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    try Data("inside".utf8).write(to: root.appendingPathComponent("docs/" + hidden))
    let source = DocumentResources(location: .local(root))
    for path in ["escape/" + hidden, "../" + hidden, "docs/../../" + hidden] {
      XCTAssertEqual(path.split(separator: "/").count < path.utf8.split(separator: UInt8(ascii: "/")).count, true, path)
      do { let data = try await source.data(at: path); XCTFail("Read \(path): \(String(decoding: data, as: UTF8.self))") } catch {}
    }
    XCTAssertEqual(try DocumentResources.components("docs/" + hidden), ["docs", hidden])
    let inside = try await source.data(at: "docs/" + hidden)
    XCTAssertEqual(String(decoding: inside, as: UTF8.self), "inside", "A name that starts with a combining mark is still a name")
    XCTAssertThrowsError(try AssetPaths.below(root, relativePath: "escape/" + hidden))
    XCTAssertThrowsError(try AssetPaths.below(root, relativePath: "../" + hidden))
  }
  @MainActor private func waitFor(_ renderer: DocumentRenderer, _ script: String) async throws {
    for _ in 0..<200 {
      if (try? await renderer.webView.evaluateJavaScript(script)) as? Bool == true { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("WebKit condition failed: \(script); \(renderer.error ?? "no error")")
  }
  @MainActor func testRealWebKitLocalScriptsFetchMarkdownAndSecurity() async throws {
    QuietWindow.prepareTestProcess()
    let root = try root()
    let online = try await HTMLHTTPFixture(files: [
      "/online.js": "window.onlineScript=true",
      "/online.css": "h1{color:rgb(10, 50, 90)}",
      "/data.json": "{\"value\":73}"
    ])
    defer { online.stop() }
    try Data("body{color:rgb(20, 40, 60)}".utf8).write(to: root.appendingPathComponent("style.css"))
    try Data(#"{"value":42}"#.utf8).write(to: root.appendingPathComponent("data.json"))
    try Data("window.localScript=true; fetch('data.json').then(r=>r.json()).then(v=>window.result=v.value).catch(e=>window.fetchError=String(e));".utf8).write(to: root.appendingPathComponent("app.js"))
    try Data("<link rel='stylesheet' href='style.css'><h1>Report</h1><input id='input'><input id='slider' type='range' oninput='window.slide=this.value'><script src='app.js'></script>".utf8).write(to: root.appendingPathComponent("report.html"))
    try Data("# Notes\n\n[Report](report.html)".utf8).write(to: root.appendingPathComponent("notes.md"))
    let renderer = DocumentRenderer()
    let window = QuietWindow(size: NSSize(width: 900, height: 700), styleMask: [.titled])
    window.contentView = renderer.webView
    XCTAssertTrue(DocumentFocus.ownsKeys(renderer.webView))
    let input = NSTextView(); renderer.webView.addSubview(input)
    XCTAssertTrue(DocumentFocus.ownsKeys(input))
    input.removeFromSuperview()
    defer { renderer.stop(); window.contentView = nil }
    renderer.show(path: "report.html", location: .local(root))
    try await waitFor(renderer, "window.result === 42")
    let localScript = try await renderer.webView.evaluateJavaScript("window.localScript") as? Bool
    XCTAssertEqual(localScript, true)
    let color = try await renderer.webView.evaluateJavaScript("getComputedStyle(document.body).color") as? String
    XCTAssertEqual(color, "rgb(20, 40, 60)")
    _ = try await renderer.webView.evaluateJavaScript("document.querySelector('#slider').value=75; document.querySelector('#slider').dispatchEvent(new Event('input')); 'ok'")
    let slide = try await renderer.webView.evaluateJavaScript("window.slide") as? String
    XCTAssertEqual(slide, "75")
    _ = try await renderer.webView.evaluateJavaScript("let script=document.createElement('script');script.src='\(online.baseURL)/online.js';document.head.append(script);let css=document.createElement('link');css.rel='stylesheet';css.href='\(online.baseURL)/online.css';document.head.append(css);fetch('\(online.baseURL)/data.json').then(r=>r.json()).then(v=>window.onlineValue=v.value);'ok'")
    try await waitFor(renderer, "window.onlineScript === true && window.onlineValue === 73 && getComputedStyle(document.querySelector('h1')).color === 'rgb(10, 50, 90)'")
    XCTAssertNil(renderer.error)
    _ = try await renderer.webView.evaluateJavaScript("fetch('file:///etc/passwd').then(()=>window.leaked=true).catch(()=>window.blocked=true);'ok'")
    try await waitFor(renderer, "window.blocked === true")
    XCTAssertFalse(renderer.webView.configuration.websiteDataStore.isPersistent)
    _ = try await renderer.webView.evaluateJavaScript("window.popup=window.open('https://example.com'); 'ok'")
    let popupBlocked = try await renderer.webView.evaluateJavaScript("window.popup === null") as? Bool
    XCTAssertEqual(popupBlocked, true)
    renderer.show(path: "notes.md", location: .local(root))
    try await waitFor(renderer, "document.querySelector('h1')?.textContent === 'Notes'")
    renderer.webView.goBack()
    try await Task.sleep(for: .milliseconds(150))
    let retainedHeading = try await renderer.webView.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
    XCTAssertEqual(retainedHeading, "Notes", "WebKit history must not bypass Frame's selection")
    renderer.back()
    try await waitFor(renderer, "window.result === 42")
  }
  @MainActor private func markdownWindow(_ renderer: DocumentRenderer) -> QuietWindow {
    let window = QuietWindow(size: NSSize(width: 900, height: 700), styleMask: [.titled])
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = renderer.webView
    return window
  }
  @MainActor func testRealWebKitMarkdownIsStaticAndKeepsImagesLinksAndPalette() async throws {
    QuietWindow.prepareTestProcess()
    let root = try root()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/markdown/diagram.png"), to: root.appendingPathComponent("images/diagram.png"))
    try Data("""
    # Notes

    <script>window.ran = true</script>

    <img src="images/diagram.png" onload="window.handled = true" onerror="window.handled = true">

    <div onmouseover="window.handled = true" style="position:fixed;inset:0">cover</div>

    ![Diagram](images/diagram.png) and [Next](next.md).
    """.utf8).write(to: root.appendingPathComponent("notes.md"))
    try Data("# Next".utf8).write(to: root.appendingPathComponent("next.md"))
    let renderer = DocumentRenderer()
    let window = markdownWindow(renderer)
    defer { renderer.stop(); window.contentView = nil }
    renderer.show(path: "notes.md", location: .local(root))
    try await waitFor(renderer, "document.readyState === 'complete' && document.querySelector('article img')?.naturalWidth > 0")
    let image = try await renderer.webView.evaluateJavaScript("document.querySelector('article img').src") as? String
    XCTAssertTrue(image?.hasPrefix("frame-document://") == true && image?.hasSuffix("/images/diagram.png") == true, image ?? "no image")
    let images = try await renderer.webView.evaluateJavaScript("document.querySelectorAll('img').length") as? Int
    XCTAssertEqual(images, 1, "the document's own <img> tag is text")
    let inert = try await renderer.webView.evaluateJavaScript("window.ran === undefined && window.handled === undefined && document.querySelectorAll('script,[onload],[onerror],[onmouseover],[style]').length === 0") as? Bool
    XCTAssertEqual(inert, true)
    let literal = try await renderer.webView.evaluateJavaScript("document.querySelector('article').textContent") as? String
    XCTAssertTrue(literal?.contains("<script>window.ran = true</script>") == true, literal ?? "")
    XCTAssertTrue(literal?.contains("onmouseover=\"window.handled = true\"") == true, literal ?? "")
    let colours = try await renderer.webView.evaluateJavaScript("[getComputedStyle(document.body).backgroundColor, getComputedStyle(document.querySelector('a[href=\"next.md\"]')).color].join(' ')") as? String
    XCTAssertEqual(colours, "rgb(248, 248, 246) rgb(60, 106, 66)")
    window.appearance = NSAppearance(named: .darkAqua)
    try await waitFor(renderer, "getComputedStyle(document.body).backgroundColor === 'rgb(36, 37, 38)' && getComputedStyle(document.querySelector('a[href=\"next.md\"]')).color === 'rgb(162, 198, 162)'")
    _ = try await renderer.webView.evaluateJavaScript("document.querySelector('a[href=\"next.md\"]').click(); true")
    try await waitFor(renderer, "document.querySelector('h1')?.textContent === 'Next'")
    XCTAssertTrue(renderer.canGoBack)
    renderer.back()
    try await waitFor(renderer, "document.querySelector('article img')?.naturalWidth > 0")
    XCTAssertNil(renderer.error)
  }
  @MainActor func testRealWebKitCopyDeliversTheBlockTextAndIgnoresForgedLinks() async throws {
    QuietWindow.prepareTestProcess()
    let root = try root()
    let swift = "let greeting = \"<hello>\"\n\tif a && b { print(greeting) }"
    try Data("# Copy\n\n```swift\n\(swift)\n```\n\n```\nplain <b> & more\n```\n\n[Forged](relaybar-copy://block/forged-token/MA)\n".utf8)
      .write(to: root.appendingPathComponent("copy.md"))
    try Data("<h1>Page</h1><figure class='code'><pre>planted</pre><a class='copy' id='forge'>Copy</a></figure>".utf8)
      .write(to: root.appendingPathComponent("page.html"))
    let renderer = DocumentRenderer()
    var copied: [String] = []
    renderer.copyToPasteboard = { copied.append($0) }
    let window = markdownWindow(renderer)
    defer { renderer.stop(); window.contentView = nil }
    func waitForCopies(_ count: Int) async throws {
      for _ in 0..<200 where copied.count < count { try await Task.sleep(for: .milliseconds(25)) }
      XCTAssertEqual(copied.count, count)
    }
    renderer.show(path: "copy.md", location: .local(root))
    try await waitFor(renderer, "document.querySelectorAll('figure.code a.copy').length === 2")
    let highlighted = try await renderer.webView.evaluateJavaScript("document.querySelector('figure.code pre.light') !== null") as? Bool
    XCTAssertEqual(highlighted, true)
    _ = try await renderer.webView.evaluateJavaScript("document.querySelectorAll('figure.code a.copy')[1].click(); true")
    try await waitForCopies(1)
    XCTAssertEqual(copied, ["plain <b> & more"])
    try await waitFor(renderer, "document.querySelectorAll('figure.code a.copy')[1].classList.contains('done')")
    _ = try await renderer.webView.evaluateJavaScript("document.querySelectorAll('figure.code a.copy')[0].click(); true")
    try await waitForCopies(2)
    XCTAssertEqual(copied.last, swift)
    try await waitFor(renderer, "!document.querySelectorAll('figure.code a.copy')[1].classList.contains('done')")
    let page = try await renderer.webView.evaluateJavaScript("location.href") as? String
    XCTAssertTrue(page?.hasSuffix("/copy.md") == true, "a Copy click never navigates")
    _ = try await renderer.webView.evaluateJavaScript("document.querySelector('a[href^=\"relaybar-copy://block/forged-token/\"]').click(); true")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(copied.count, 2, "a Copy link without this page's token does nothing")
    // An HTML document can read the host, but its links are not the renderer's.
    renderer.show(path: "page.html", location: .local(root))
    try await waitFor(renderer, "document.querySelector('h1')?.textContent === 'Page'")
    _ = try await renderer.webView.evaluateJavaScript("const a = document.getElementById('forge'); a.href = 'relaybar-copy://block/' + location.host + '/MA'; a.click(); true")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(copied.count, 2)
    let stayed = try await renderer.webView.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
    XCTAssertEqual(stayed, "Page")
    // Nor can it pass for a Markdown page by rewriting its own address.
    _ = try await renderer.webView.evaluateJavaScript("history.replaceState(null, '', 'spoof.md'); const b = document.getElementById('forge'); b.href = 'relaybar-copy://block/' + location.host + '/MA'; b.click(); location.pathname")
    try await waitFor(renderer, "location.pathname.endsWith('/spoof.md')")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(copied.count, 2, "what the renderer loaded decides, not the address the page shows")
    // A real Markdown page loaded afterwards can copy again.
    renderer.show(path: "copy.md", location: .local(root))
    try await waitFor(renderer, "document.querySelectorAll('figure.code a.copy').length === 2")
    _ = try await renderer.webView.evaluateJavaScript("document.querySelectorAll('figure.code a.copy')[1].click(); true")
    try await waitForCopies(3)
    XCTAssertEqual(copied.last, "plain <b> & more")
  }
  @MainActor func testRealWebKitLargeMarkdownRendersPlainAndInert() async throws {
    QuietWindow.prepareTestProcess()
    let root = try root()
    let head = "---\ntitle: Large\n---\n\n# Large\n\n<script>window.ran = true</script>\n\n<img src=\"x\" onerror=\"window.ran = true\">\n\n```swift\nlet a = 1\n```\n\n"
    let source = head + String(repeating: String(repeating: "filler ", count: 150) + "\n\n", count: MarkdownRenderer.maximumEnrichedByteCount / 1_050 + 1)
    XCTAssertGreaterThan(source.utf8.count, MarkdownRenderer.maximumEnrichedByteCount)
    try Data(source.utf8).write(to: root.appendingPathComponent("large.md"))
    let renderer = DocumentRenderer()
    var copied: [String] = []
    renderer.copyToPasteboard = { copied.append($0) }
    let window = markdownWindow(renderer)
    defer { renderer.stop(); window.contentView = nil }
    renderer.show(path: "large.md", location: .local(root))
    try await waitFor(renderer, "document.readyState === 'complete' && document.querySelector('article h1')?.textContent === 'Large'")
    let state = try await renderer.webView.evaluateJavaScript("""
    [window.ran === undefined, document.querySelectorAll('script,img').length, document.body.textContent.includes('Properties'), document.querySelector('figure.code pre').className].join(' ')
    """) as? String
    XCTAssertEqual(state, "true 0 false ")
    _ = try await renderer.webView.evaluateJavaScript("document.querySelector('figure.code a.copy').click(); true")
    for _ in 0..<200 where copied.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertEqual(copied, ["let a = 1"])
  }
  @MainActor func testRemoteWebKitFetchesOnlyRequestedResourcesAndRefreshesChangedBytes() async throws {
    QuietWindow.prepareTestProcess()
    let root = try root(), fixture = DocumentBridgeFixture(root: root)
    let client = RelayRemoteClient(transport: { try await fixture.send($0) }, cacheRoot: root.appendingPathComponent("cache"), sharedRoot: { root })
    let source = BridgeSource(id: String(repeating: "d", count: 64), name: "Documents")
    let listing = try await client.list(source: source, path: "/project")
    XCTAssertEqual(listing.files.count, 6)
    let before = await fixture.fetches
    XCTAssertTrue(before.isEmpty)
    let renderer = DocumentRenderer(client: client)
    let window = QuietWindow(size: NSSize(width: 900, height: 700), styleMask: [.titled])
    window.contentView = renderer.webView
    defer { renderer.stop(); window.contentView = nil }
    renderer.show(path: "report.html", location: .remote(source, "/project"))
    try await waitFor(renderer, "window.result === 42")
    let initial = await fixture.fetches
    XCTAssertEqual(Set(initial), ["report.html", "app.js", "data.json", "style.css"])
    await fixture.changeData()
    await renderer.refresh()
    try await waitFor(renderer, "window.result === 99")
    let updated = await fixture.fetches
    XCTAssertEqual(updated.filter { $0 == "data.json" }.count, 2)
    XCTAssertEqual(updated.filter { $0 == "report.html" }.count, 1)
    renderer.show(path: "notes.md", location: .remote(source, "/project"))
    try await waitFor(renderer, "document.querySelector('h1')?.textContent === 'Remote notes'")
    renderer.back()
    try await waitFor(renderer, "window.result === 99")
    let final = await fixture.fetches, batches = await fixture.statBatches
    XCTAssertEqual(final.count, updated.count + 1)
    XCTAssertTrue(batches.contains { $0.count == 4 })
    XCTAssertFalse(final.contains("unused.mp4"))
    await fixture.disconnect()
    await renderer.refresh()
    XCTAssertEqual(renderer.error, "Connection unavailable. Retry.")
    let retained = try await renderer.webView.evaluateJavaScript("window.result") as? Int
    XCTAssertEqual(retained, 99)
  }
  @MainActor func testAPageStillOnShowCannotReadTheNextLibrarysFiles() async throws {
    QuietWindow.prepareTestProcess()
    let first = try root(), shared = try root()
    try Data("<h1>First</h1>".utf8).write(to: first.appendingPathComponent("page.html"))
    try Data("first's own".utf8).write(to: first.appendingPathComponent("own.txt"))
    let fixture = HandoverFixture(root: shared)
    let client = RelayRemoteClient(transport: { try await fixture.send($0) }, cacheRoot: shared.appendingPathComponent("cache"), sharedRoot: { shared })
    let source = BridgeSource(id: String(repeating: "d", count: 64), name: "Second")
    let renderer = DocumentRenderer(client: client)
    let window = QuietWindow(size: NSSize(width: 900, height: 700), styleMask: [.titled])
    window.contentView = renderer.webView
    defer { renderer.stop(); window.contentView = nil }
    renderer.show(path: "page.html", location: .local(first))
    try await waitFor(renderer, "document.querySelector('h1')?.textContent === 'First'")
    _ = try await renderer.webView.evaluateJavaScript("fetch('own.txt').then(r=>r.text()).then(t=>window.own=t);'ok'")
    try await waitFor(renderer, "window.own === \"first's own\"")
    let firstHost = try XCTUnwrap(renderer.webView.url?.host)
    // The next library's document is slow to arrive, so the first page stays committed meanwhile.
    renderer.stop()
    renderer.show(path: "page.html", location: .remote(source, "/second"))
    try await fixture.gate.waitFor("page.html")
    let committed = try await renderer.webView.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
    XCTAssertEqual(committed, "First")
    _ = try await renderer.webView.evaluateJavaScript("""
    fetch('secret.txt').then(r=>r.ok?r.text():Promise.reject(r.status)).then(t=>window.leaked=t).catch(()=>window.blocked=true);\
    fetch('own.txt').then(r=>r.ok?r.text():Promise.reject(r.status)).then(t=>window.leaked=t).catch(()=>window.ownBlocked=true);'ok'
    """)
    try await waitFor(renderer, "window.blocked === true && window.ownBlocked === true")
    let leaked = try await renderer.webView.evaluateJavaScript("window.leaked === undefined") as? Bool
    XCTAssertEqual(leaked, true, "A page is served only from the source it was loaded from")
    let fetched = await fixture.fetches
    XCTAssertEqual(fetched, ["page.html"], "Nothing of the second library was read for the first page")
    await fixture.gate.releaseAll()
    try await waitFor(renderer, "document.querySelector('h1')?.textContent === 'Second'")
    XCTAssertNotEqual(renderer.webView.url?.host, firstHost)
    _ = try await renderer.webView.evaluateJavaScript("fetch('secret.txt').then(r=>r.text()).then(t=>window.secret=t);'ok'")
    try await waitFor(renderer, "window.secret === 'second secret'")
  }
  @MainActor func testComposedRemoteDocumentFreezesWithoutAuthorityAndReloadsAfterReconnect() async throws {
    QuietWindow.prepareTestProcess()
    let root = try root(), fixture = DocumentBridgeFixture(root: root)
    let link = FrameRemoteLink(transport: { try await fixture.send($0) }, sharedRoot: { root })
    let features = FrameComposition(link: link)
    _ = try await features.client.catalog()
    let source = BridgeSource(id: String(repeating: "d", count: 64), name: "Documents")
    let listing = try await features.client.list(source: source, path: "/project")
    let photo = try XCTUnwrap(listing.files.first { $0.name == "report.html" })
    let renderer = features.documentRenderer
    let window = QuietWindow(size: NSSize(width: 900, height: 700), styleMask: [.titled])
    window.contentView = renderer.webView
    defer { window.contentView = nil }
    features.showDocument(photo, path: "report.html", location: .remote(source, "/project"))
    try await waitFor(renderer, "window.result === 42")
    await fixture.disconnect()
    await renderer.refresh()
    await link.settle()
    XCTAssertFalse(link.isConnected)
    XCTAssertNotNil(renderer.error)
    let priorFetches = await fixture.fetches
    renderer.retry()
    let retained = try await renderer.webView.evaluateJavaScript("window.result") as? Int
    XCTAssertEqual(retained, 42)
    XCTAssertFalse(renderer.loading)
    let afterFetches = await fixture.fetches
    XCTAssertEqual(priorFetches, afterFetches)
    features.showDocument(photo, path: "report.html", location: .remote(source, "/project"))
    try await Task.sleep(for: .milliseconds(100))
    let failedRetryRetained = try await renderer.webView.evaluateJavaScript("window.result") as? Int
    XCTAssertEqual(failedRetryRetained, 42, "A failed explicit reconnect must retain the last-good page")
    await fixture.reconnect(); await fixture.changeData()
    _ = try await features.client.catalog()
    features.showDocument(photo, path: "report.html", location: .remote(source, "/project"))
    try await waitFor(renderer, "window.result === 99")
    await features.stop()
  }

  @MainActor func testLocalWatcherUpdatesOnlyExpandedBranchesAndPreservesMissingSelection() async throws {
    let root = try root()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
    try Data("# One".utf8).write(to: root.appendingPathComponent("notes.md"))
    let catalog = try ModelContainer(for: LibraryRootRecord.self, FavoriteRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = LibraryStore(defaults: UserDefaults(suiteName: "DocumentWatcher.\(UUID())")!)
    await store.start(modelContext: catalog.mainContext)
    await store.openRoot(root)
    let selected = store.selectionID
    XCTAssertEqual(store.viewMode, .inspect)
    XCTAssertEqual(store.localFolders?.results.count, 1)
    try Data("# Two".utf8).write(to: root.appendingPathComponent("second.md"), options: .atomic)
    for _ in 0..<100 where store.files(in: "").count < 2 { try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertEqual(store.files(in: "").count, 2)
    XCTAssertEqual(store.selectionID, selected)
    XCTAssertEqual(store.localFolders?.results.count, 1)
    try FileManager.default.removeItem(at: root.appendingPathComponent("notes.md"))
    for _ in 0..<100 where !store.selectionMissing { try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertTrue(store.selectionMissing)
    XCTAssertEqual(store.selectionID, selected)
    store.localFolders?.stop()
  }
  @MainActor func testTenThousandEntriesAndTwoHundredRendererSwitches() async throws {
    QuietWindow.prepareTestProcess()
    let root = try root()
    for index in 0..<10_000 {
      let html = index % 2 == 0
      try Data((html ? "<h1>File \(index)</h1>" : "# File \(index)").utf8).write(to: root.appendingPathComponent("\(index).\(html ? "html" : "md")"))
    }
    let start = ContinuousClock.now
    let scan = try await Task.detached { try FileScanner.directory(rootURL: root, rootID: UUID(), path: "") }.value
    let listingTime = start.duration(to: .now)
    XCTAssertEqual(scan.files.count, 10_000)
    XCTAssertLessThan(listingTime, .seconds(5))
    let renderer = DocumentRenderer()
    let window = QuietWindow(size: NSSize(width: 900, height: 700), styleMask: [.titled])
    window.contentView = renderer.webView
    defer { renderer.stop(); window.contentView = nil }
    let webView = renderer.webView
    let switches = ContinuousClock.now
    var memory = rusage(), halfway: Int64 = 0
    for index in 0..<200 {
      renderer.show(path: "\(index).\(index % 2 == 0 ? "html" : "md")", location: .local(root))
      try await waitFor(renderer, "document.querySelector('h1')?.textContent === 'File \(index)'")
      XCTAssertTrue(renderer.webView === webView)
      if index == 99 { getrusage(RUSAGE_SELF, &memory); halfway = Int64(memory.ru_maxrss) }
    }
    getrusage(RUSAGE_SELF, &memory)
    print("Document performance: 10,000 entries \(listingTime); 200 Markdown/HTML switches \(switches.duration(to: .now)); one WKWebView; test-process peak RSS at 100/200: \(halfway)/\(memory.ru_maxrss) bytes")
  }
}

/// A remote library whose document download waits at a gate the test opens.
private actor HandoverFixture {
  let root: URL
  let gate = KeyedGate(failure: "The second library's document was never requested", timeout: CancellationError())
  var fetches: [String] = []
  let files = ["page.html": Data("<h1>Second</h1>".utf8), "secret.txt": Data("second secret".utf8)]
  init(root: URL) { self.root = root }
  func send(_ request: BridgeRequest) async throws -> BridgeResponse {
    var response = BridgeResponse()
    switch request.operation {
    case "list":
      response.listingID = UUID()
      response.entries = files.keys.sorted().map {
        BridgeEntry(name: $0, path: "/second/" + $0, directory: false, size: Int64(files[$0]!.count), modified: "0", fingerprint: $0)
      }
    case "fetch":
      let name = request.name!, job = UUID(), folder = "FrameTransfers-fixture/\(job)"
      fetches.append(name)
      if name == "page.html" { await gate.wait(name) }
      let directory = root.appendingPathComponent(folder)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try files[name]!.write(to: directory.appendingPathComponent(name))
      response.jobID = job; response.cacheRelativePath = folder + "/" + name
    case "documentStat":
      var result = BridgeAssetResult()
      result.entries = (request.paths ?? []).compactMap { path in
        let name = (path as NSString).lastPathComponent
        return files[name].map { BridgeEntry(name: name, path: path, directory: false, size: Int64($0.count), modified: "0", fingerprint: name) }
      }
      response.asset = result
    case "release": break
    default: throw BridgeError("Unexpected bridge request: \(request.operation)")
    }
    return response
  }
}

private actor DocumentBridgeFixture {
  let root: URL
  var fetches: [String] = []
  var statBatches: [[String]] = []
  var offline = false
  var files: [String: Data] = [
    "report.html": Data("<link rel='stylesheet' href='style.css'><h1>Remote report</h1><script src='app.js'></script>".utf8),
    "style.css": Data("body{font:18px system-ui}".utf8),
    "app.js": Data("fetch('data.json').then(r=>r.json()).then(v=>window.result=v.value)".utf8),
    "data.json": Data(#"{"value":42}"#.utf8),
    "notes.md": Data("# Remote notes\n\n[Report](report.html)".utf8),
    "unused.mp4": Data("not requested".utf8)
  ]
  var version = 0
  init(root: URL) { self.root = root }
  func changeData() { files["data.json"] = Data(#"{"value":99}"#.utf8); version += 1 }
  func disconnect() { offline = true }
  func reconnect() { offline = false }
  func entry(_ name: String) -> BridgeEntry {
    BridgeEntry(name: name, path: "/project/" + name, directory: false, size: Int64(files[name]!.count), modified: "0", fingerprint: name + "-\(name == "data.json" ? version : 0)")
  }
  func send(_ request: BridgeRequest) throws -> BridgeResponse {
    if offline { throw BridgeError("Disconnected", sessionFailure: .unavailable) }
    var response = BridgeResponse()
    switch request.operation {
    case "catalog": response.sources = [BridgeSource(id: String(repeating: "d", count: 64), name: "Documents")]
    case "list": response.listingID = UUID(); response.entries = files.keys.sorted().map(entry)
    case "fetch":
      let name = request.name!, job = UUID(), folder = "FrameTransfers-fixture/\(job)"
      fetches.append(name)
      let directory = root.appendingPathComponent(folder)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try files[name]!.write(to: directory.appendingPathComponent(name))
      response.jobID = job; response.cacheRelativePath = folder + "/" + name
    case "documentStat":
      statBatches.append(request.paths ?? [])
      var result = BridgeAssetResult(); result.entries = (request.paths ?? []).compactMap { path in
        let name = (path as NSString).lastPathComponent
        return files[name] == nil ? nil : entry(name)
      }; response.asset = result
    case "release": break
    default: throw BridgeError("Unexpected bridge request: \(request.operation)")
    }
    return response
  }
}
