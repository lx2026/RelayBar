enum HeadingTracking {
  // Run in the reader's isolated client world against the current DOM geometry.
  static let script = """
    const nodes = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6'));
    const index = nodes.findLastIndex(e => e.getBoundingClientRect().top <= 1);
    const node = nodes[index];
    """
}

#if os(iOS)
  import HouseStyle
  import MarkdownRendering
  import MobileCore
  import SwiftUI
  import UniformTypeIdentifiers
  import WebKit

  struct MarkdownView: UIViewRepresentable {
    let html: String
    let id: UUID
    let path: String
    let files: (any RemoteFiles)?
    let position: ReadingPosition
    let token: String
    let blocks: [String]
    @Binding var headings: [OutlineHeading]
    @Binding var jump: Int?
    var track: (Int?, Double) -> Void = { _, _ in }
    let save: (ReadingPosition, String?) -> Void

    @Environment(\.dynamicTypeSize) var typeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.defaultWebpagePreferences.allowsContentJavaScript = false
      config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: "relay-document")
      let view = WKWebView(frame: .zero, configuration: config)
      view.navigationDelegate = context.coordinator
      view.scrollView.delegate = context.coordinator
      view.isOpaque = false
      view.backgroundColor = .clear
      return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
      let coordinator = context.coordinator
      coordinator.parent = self
      coordinator.handler.files = files
      coordinator.handler.html = pageHTML
      view.pageZoom = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16) / 16
      if coordinator.loaded != id {
        coordinator.loaded = id
        coordinator.restored = false
        view.load(URLRequest(url: coordinator.mainURL))
      } else if let index = jump {
        Task { @MainActor in
          jump = nil
          _ = try? await view.callAsyncJavaScript(
            "document.querySelectorAll('h1,h2,h3,h4,h5,h6')[index]?.scrollIntoView()",
            arguments: ["index": index], in: nil, contentWorld: .defaultClient)
        }
      }
    }
    private var pageHTML: String {
      let policy =
        "default-src 'none'; img-src relay-document: data:; style-src relay-document: 'unsafe-inline'; font-src relay-document:; media-src relay-document:; base-uri 'none'; form-action 'none'"
      return """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        """ + html
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
      var parent: MarkdownView
      var loaded: UUID?
      var restored = false
      let handler: DocumentSchemeHandler
      var mainURL: URL { handler.scheme.mainURL }
      var nextCapture = ContinuousClock.now
      weak var web: WKWebView?
      init(_ parent: MarkdownView) {
        self.parent = parent
        handler = DocumentSchemeHandler(
          path: parent.path, html: parent.pageHTML, files: parent.files)
      }

      func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async
        -> WKNavigationActionPolicy
      {
        if action.navigationType == .linkActivated, let url = action.request.url,
          let index = MarkdownRenderer.copiedBlockIndex(from: url, referenceToken: parent.token),
          parent.blocks.indices.contains(index)
        {
          UIPasteboard.general.string = parent.blocks[index]
        }
        return action.request.url == mainURL && action.navigationType == .other
          && action.targetFrame?.isMainFrame == true ? .allow : .cancel
      }

      func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        web = webView
        let position = parent.position
        Task {
          let result = try? await webView.callAsyncJavaScript(
            """
            const nodes = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6'));
            const target = nodes.find(e => e.textContent === heading);
            scrollTo(0, target ? target.getBoundingClientRect().top + scrollY + offset : absolute);
            return nodes.map(e => ({text: e.textContent, level: Number(e.tagName.slice(1))}))
            """,
            arguments: [
              "heading": position.heading ?? "", "offset": position.offset,
              "absolute": position.absoluteOffset,
            ],
            in: nil, contentWorld: .defaultClient)
          parent.headings = (result as? [[String: Any]] ?? []).compactMap { values in
            guard let text = values["text"] as? String, let level = values["level"] as? Int else {
              return nil
            }
            return OutlineHeading(text: text, level: level)
          }
          restored = true
          capture()
        }
      }
      func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard ContinuousClock.now >= nextCapture, restored else { return }
        nextCapture = .now + .milliseconds(500)
        capture()
      }
      func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { capture() }
      func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { capture() }
      }
      func capture() {
        guard restored, let web else { return }
        Task {
          let result = try? await web.callAsyncJavaScript(
            """
            \(HeadingTracking.script)
            const paragraph = Array.from(document.querySelectorAll('article p')).find(e => {
              const rect = e.getBoundingClientRect(); return rect.bottom > 0 && rect.top < innerHeight;
            });
            return {index, progress: scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight), excerpt: paragraph?.textContent.slice(0, 200) ?? null, heading: node?.textContent ?? null, offset: node ? -node.getBoundingClientRect().top : 0, absolute: scrollY}
            """, in: nil, contentWorld: .defaultClient)
          if let dict = result as? [String: Any], let absolute = dict["absolute"] as? Double {
            parent.track(max(0, dict["index"] as? Int ?? 0), dict["progress"] as? Double ?? 0)
            parent.save(
              .init(
                heading: dict["heading"] as? String, offset: dict["offset"] as? Double ?? 0,
                absoluteOffset: absolute), dict["excerpt"] as? String)
          }
        }
      }
    }
  }
#endif
