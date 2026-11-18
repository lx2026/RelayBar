import AppKit
import Composition
import HouseStyle
import WebKit
import XCTest
@testable import FrameKit

/// Frame draws from the shared house palette: unchanged while Paper Appearance is on, standard macOS colours while
/// it is off, with the choice stored and applied like any plugin.
@MainActor
final class PaperAppearanceTests: XCTestCase {
  override func tearDown() {
    HousePalette.apply(.paper)
    super.tearDown()
  }

  /// The values Frame drew with before the palette moved to the shared package.
  func testWithThePluginOnFrameDrawsExactlyAsBefore() {
    HousePalette.apply(.paper)
    let before: [(NSColor, UInt32, UInt32)] = [
      (FrameColors.paper, 0xf8f8f6, 0x242526), (FrameColors.panel, 0xf0f0ed, 0x292a2b), (FrameColors.stage, 0xe4e5e1, 0x17191a),
      (FrameColors.card, 0xffffff, 0x343637), (FrameColors.ink, 0x252823, 0xeeefeb), (FrameColors.muted, 0x585d54, 0xb5b9b0),
      (FrameColors.faint, 0x8b8f86, 0x80847c), (FrameColors.selected, 0xd4d7cf, 0x3d403b), (FrameColors.amber, 0x805000, 0xf1bd62),
      (FrameColors.red, 0xb8241a, 0xff6b62), (FrameColors.button, 0x30352d, 0xe2e6dc), (FrameColors.buttonText, 0xffffff, 0x252823)
    ]
    for (color, light, dark) in before {
      XCTAssertEqual(hex(color, .aqua), light)
      XCTAssertEqual(hex(color, .darkAqua), dark)
    }
    XCTAssertEqual(alpha(FrameColors.line, .aqua), 0.12, accuracy: 0.001)
    XCTAssertEqual(alpha(FrameColors.fill, .darkAqua), 0.08, accuracy: 0.001)
    // The Markdown page's style sheet is the one Frame used before, with only a marker added.
    let page = """
    :root{--md-bg:#f8f8f6;--md-text:#242821;--md-secondary:rgba(36,40,33,.6);--md-link:#3c6a42;--md-accent-rgb:60,106,66}
    @media(prefers-color-scheme:dark){:root{--md-bg:#242526;--md-text:#e3e6df;--md-secondary:rgba(227,230,223,.6);--md-link:#a2c6a2;--md-accent-rgb:98,148,104}}
    article{padding-top:16px}
    """
    XCTAssertEqual(DocumentHTML.palette.replacingOccurrences(of: "--frame-page:1;", with: ""), page)
  }

  func testWithThePluginOffFrameDrawsInStandardColoursAndThePageStillMatchesThePaper() {
    HousePalette.apply(.standard)
    for (name, system) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
      XCTAssertEqual(hex(FrameColors.paper, name), hex(.windowBackgroundColor, name))
      XCTAssertEqual(hex(FrameColors.ink, name), hex(.labelColor, name))
      XCTAssertTrue(DocumentHTML.palette.contains(HousePalette.paper.css(in: .standard, dark: system)))
      XCTAssertTrue(DocumentHTML.paperStyle(DocumentPaper(form: .standard)).contains("--md-bg:" + HousePalette.paper.css(in: .standard, dark: system)))
    }
  }

  func testThePluginIsListedOnByDefaultAndItsChoiceAppliesBeforeTheNextWindow() async throws {
    XCTAssertEqual(FramePlugins.all.map(\.id), ["prompt-search", "paper"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FramePaper-\(UUID())")
    let storage = root.appendingPathComponent("preferences.json")
    defer { try? FileManager.default.removeItem(at: root) }
    HousePalette.apply(.standard)
    let first = FrameComposition(preferencesURL: storage)
    XCTAssertEqual(HousePalette.form, .paper, "on by default")
    try await first.start()
    XCTAssertTrue(first.isPluginEnabled(FramePlugins.paperAppearance))
    let ids = first.runtime.statuses.map(\.id)
    let redraw = expectation(forNotification: HousePalette.didChangeNotification, object: nil)
    try await first.setPlugin(FramePlugins.paperAppearance, enabled: false)
    await fulfillment(of: [redraw], timeout: 1)
    XCTAssertEqual(HousePalette.form, .standard)
    XCTAssertEqual(first.runtime.statuses.map(\.id), ids, "no feature comes or goes")
    await first.stop()
    XCTAssertTrue(try String(contentsOf: storage, encoding: .utf8).contains(#""paper" : false"#))

    HousePalette.apply(.paper)
    let reopened = FrameComposition(preferencesURL: storage)
    XCTAssertEqual(HousePalette.form, .standard, "applied when the composition is made, before Frame's window")
    try await reopened.start()
    XCTAssertFalse(reopened.isPluginEnabled(FramePlugins.paperAppearance))
    await reopened.stop()
  }

  /// A Markdown page already on show takes the new paper at once, without being loaded again.
  func testAPageOnShowFollowsTheFormWithoutReloading() async throws {
    HousePalette.apply(.paper)
    QuietWindow.prepareTestProcess()
    let folder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/markdown")
    let renderer = DocumentRenderer()
    let window = QuietWindow(size: NSSize(width: 600, height: 400), styleMask: [.titled])
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = renderer.webView
    window.orderInOffscreen()
    defer { renderer.stop(); window.orderOut(nil); window.contentView = nil }
    renderer.show(path: "ordinary.md", location: .local(folder))
    func background() async -> String? {
      try? await renderer.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
    }
    func rgb(_ form: HouseForm) -> String {
      let c = components(HousePalette.paper.nsColor(in: form), .aqua)
      return "rgb(" + [c.redComponent, c.greenComponent, c.blueComponent].map { String(Int(($0 * 255).rounded())) }
        .joined(separator: ", ") + ")"
    }
    var loaded = false
    for _ in 0..<400 where !loaded {
      loaded = (try? await renderer.webView.evaluateJavaScript("document.querySelector('article h1') !== null") as? Bool) == true
      if !loaded { try await Task.sleep(for: .milliseconds(25)) }
    }
    XCTAssertTrue(loaded, renderer.error ?? "the page did not load")
    let paper = await background()
    XCTAssertEqual(paper, rgb(.paper))
    let marker = try await renderer.webView.evaluateJavaScript("document.body.dataset.kept = 'yes'; 1")
    XCTAssertNotNil(marker)

    HousePalette.apply(.standard)
    var followed: String?
    for _ in 0..<200 {
      followed = await background()
      if followed == rgb(.standard) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotEqual(rgb(.paper), rgb(.standard))
    XCTAssertEqual(followed, rgb(.standard))
    let kept = try await renderer.webView.evaluateJavaScript("document.body.dataset.kept") as? String
    XCTAssertEqual(kept, "yes", "the page was not loaded again")
  }

  /// A page made in one form and shown after a switch takes the paper of the form in use when it finishes loading.
  func testAPageMadeBeforeASwitchTakesTheNewPaperWhenItLoads() async throws {
    HousePalette.apply(.paper)
    let stale = DocumentHTML.markdown("# Made before the switch\n\nText.", referenceToken: "t", paper: DocumentPaper(form: .paper))
    HousePalette.apply(.standard)
    QuietWindow.prepareTestProcess()
    let renderer = DocumentRenderer()
    let window = QuietWindow(size: NSSize(width: 600, height: 400), styleMask: [.titled])
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = renderer.webView
    window.orderInOffscreen()
    defer { renderer.stop(); window.orderOut(nil); window.contentView = nil }
    renderer.webView.loadHTMLString(stale, baseURL: nil)
    let standard = components(HousePalette.paper.nsColor(in: .standard), .aqua)
    let expected = "rgb(" + [standard.redComponent, standard.greenComponent, standard.blueComponent]
      .map { String(Int(($0 * 255).rounded())) }.joined(separator: ", ") + ")"
    var background: String?
    for _ in 0..<400 where background != expected {
      background = try? await renderer.webView.evaluateJavaScript("document.querySelector('article h1') ? getComputedStyle(document.body).backgroundColor : null") as? String
      if background != expected { try await Task.sleep(for: .milliseconds(25)) }
    }
    XCTAssertTrue(stale.contains(DocumentPaper(form: .paper).light))
    XCTAssertEqual(background, expected)
  }

  /// Writes Frame's Markdown page with the plugin on and off, light and dark, when `FRAME_SNAPSHOT_DIR` is set.
  func testWritesPaperAppearanceDocumentSnapshots() async throws {
    guard let path = ProcessInfo.processInfo.environment["FRAME_SNAPSHOT_DIR"], !path.isEmpty else {
      throw XCTSkip("Set FRAME_SNAPSHOT_DIR to write Markdown snapshots.")
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    QuietWindow.prepareTestProcess()
    let folder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/markdown")
    let size = NSSize(width: 767, height: 748)
    for form in HouseForm.allCases {
      HousePalette.apply(form)
      for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let renderer = DocumentRenderer()
        let window = QuietWindow(size: size, styleMask: [.titled])
        window.appearance = NSAppearance(named: appearance)
        window.contentView = renderer.webView
        window.orderInOffscreen()
        renderer.show(path: "ordinary.md", location: .local(folder))
        for _ in 0..<400 {
          if (try? await renderer.webView.evaluateJavaScript("document.querySelector('article h1') !== null") as? Bool) == true { break }
          try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(400))
        let image = try await renderer.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let plugin = form == .paper ? "on" : "off"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: directory.appendingPathComponent("069-frame-markdown-paper-\(plugin)-\(label).png"))
        renderer.stop()
        await renderer.finishStopping()
        window.orderOut(nil)
        window.contentView = nil
      }
    }
  }

  private func components(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
    var result = color
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
    return result
  }

  private func hex(_ color: NSColor, _ name: NSAppearance.Name) -> UInt32 {
    let c = components(color, name)
    return [c.redComponent, c.greenComponent, c.blueComponent].reduce(UInt32(0)) { $0 << 8 | UInt32(($1 * 255).rounded()) }
  }

  private func alpha(_ color: NSColor, _ name: NSAppearance.Name) -> CGFloat { components(color, name).alphaComponent }
}
