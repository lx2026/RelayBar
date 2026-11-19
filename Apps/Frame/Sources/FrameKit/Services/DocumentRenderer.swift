import BridgeProtocol
import AssetGrouping
import AppKit
import Combine
import Composition
import Foundation
import HouseStyle
import MarkdownRendering
import UniformTypeIdentifiers
import WebKit

/// A single ephemeral WebKit view. Custom-scheme reads cannot reach arbitrary URLs or app actions.
@MainActor public final class DocumentRenderer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
  @Published public private(set) var error: String?
  @Published public private(set) var loading = false
  @Published public private(set) var canGoBack = false
  @Published public private(set) var canGoForward = false
  /// Shows Markdown and HTML as their own text instead of rendered. Holds for the renderer's life.
  @Published public private(set) var showsSource = false
  /// The second- and third-level headings of the Markdown page on show, and the one being read.
  @Published public private(set) var outline: [DocumentHeading] = []
  @Published public private(set) var activeHeading: Int?
  @Published public private(set) var hasPageOutline = false
  public private(set) var webView: WKWebView!
  public var onNavigate: ((String) -> Void)?
  /// Receives a code block's text from its Copy link; replaceable so tests leave the real pasteboard alone.
  var copyToPasteboard: (String) -> Void = { text in
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
  }
  private var source: DocumentResources?
  private var location: DocumentLocation?
  private var path: String?
  /// The host of the source in use. Each location gets a new source and so a new host: a page still on show from
  /// the last location keeps its old host, which reaches nothing once the new source is in place.
  private var host: String? { source?.host }
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var loadTask: Task<Void, Never>?
  private var pollTask: Task<Void, Never>?
  private var generation = UUID()
  /// The page WebKit actually committed can lag behind the file selected in the tree.
  @Published private var displayedPage: (location: DocumentLocation, path: String)?
  private var pendingPage: (navigation: WKNavigation, location: DocumentLocation, path: String)?
  public func isDisplaying(path: String, location: DocumentLocation?) -> Bool {
    guard let displayedPage else { return false }
    return displayedPage.path == path && displayedPage.location == location
  }

  private var showsMarkdown = false
  private var prepared: (host: String, path: String, data: Data)?
  private var pendingScroll: Double?
  private var refreshing = false
  private var history: [(String, Double)] = []
  private var historyIndex = -1
  private let parser = DocumentParser()
  private let client: (any RemoteAssetServing)?
  private var documentLimit = DocumentResources.documentLimit
  private var work = EffectScope()
  private var retirement: Task<Void, Never>?
  private var active = false
  private var paperObservation: AnyCancellable?

  public init(client: (any RemoteAssetServing)? = nil) {
    self.client = client
    super.init()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(WeakDocumentScheme(self), forURLScheme: "frame-document")
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.mediaTypesRequiringUserActionForPlayback = .all
    // This handler reports a resource failure only; it cannot invoke any file/app command.
    config.userContentController.add(WeakDocumentMessage(self), name: "resourceBlocked")
    config.userContentController.addUserScript(WKUserScript(source: """
    document.addEventListener('securitypolicyviolation',()=>window.webkit.messageHandlers.resourceBlocked.postMessage('blocked'));
    document.addEventListener('DOMContentLoaded',()=>{const used=new Set();document.querySelectorAll('article h1,article h2,article h3,article h4').forEach(h=>{if(!h.id){let s=h.textContent.toLowerCase().replace(/[^\\p{L}\\p{N} _-]/gu,'').replace(/ +/g,'-'),id=s,n=1;while(used.has(id))id=s+'-'+n++;used.add(id);h.id=id;}});});
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    // The outline is read by Frame's own script in an isolated world; the page's scripts cannot see it or its
    // message handler, and the page's script and content policies are unchanged.
    config.userContentController.add(WeakDocumentMessage(self), contentWorld: .defaultClient, name: Self.outlineMessage)
    config.userContentController.addUserScript(WKUserScript(source: Self.outlineScript, injectionTime: .atDocumentEnd,
                                                            forMainFrameOnly: true, in: .defaultClient))
    webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = self; webView.uiDelegate = self
    webView.setValue(false, forKey: "drawsBackground")
    webView.allowsBackForwardNavigationGestures = false
    paperObservation = NotificationCenter.default.publisher(for: HousePalette.didChangeNotification)
      .sink { [weak self] _ in self?.followPaper() }
  }

  /// A page on show keeps the reader column's paper when the form changes, and a page that finishes loading takes the
  /// paper of the form in use then, even if it was made before a change; a page that brings its own colours is left
  /// alone.
  private func followPaper() {
    let style = DocumentHTML.paperStyle(.current).replacingOccurrences(of: "'", with: "\\'")
    webView.evaluateJavaScript("""
    (()=>{if(!getComputedStyle(document.documentElement).getPropertyValue('--frame-page'))return false;\
    let s=document.getElementById('frame-paper');if(!s){s=document.createElement('style');s.id='frame-paper';\
    (document.head||document.documentElement).appendChild(s)}s.textContent='\(style)';return true})()
    """, in: nil, in: .defaultClient) { _ in }
  }
  public func stop() {
    active = false; generation = UUID(); loading = false
    pendingPage = nil
    clearOutline()
    loadTask?.cancel(); loadTask = nil; pollTask?.cancel(); pollTask = nil
    for task in tasks.values { task.cancel() }; tasks.removeAll()
    webView.stopLoading()
    let previous = retirement, retired = work, source = source
    work = EffectScope()
    retirement = Task { await previous?.value; await retired.dispose(); await source?.clear() }
  }
  public func finishStopping() async { await retirement?.value }
  public func suspendRemote(_ message: String) {
    guard case .remote = location else { return }
    stop()
    error = message
  }
  public func connectionUnavailable(_ message: String, location: DocumentLocation, path: String) {
    if self.location == location, self.path == path { suspendRemote(message) }
    else { showFailure(message) }
  }
  public func clearPreview() {
    showFailure("Preview is disabled. Enable it in Settings.")
  }
  public func showFailure(_ message: String) {
    stop()
    hasPageOutline = false
    prepared = nil
    displayedPage = nil
    webView.loadHTMLString("<style>\(DocumentHTML.theme)</style><article>Preview unavailable</article>", baseURL: nil)
    error = message
  }
  public func show(path: String, location: DocumentLocation, recordHistory: Bool = true,
                   maximumBytes: Int = DocumentResources.documentLimit) {
    error = nil
    let changedLimit = documentLimit != maximumBytes || !active
    active = true
    documentLimit = min(DocumentResources.documentLimit, max(1, maximumBytes))
    let settling = retirement
    loadTask?.cancel()
    guard self.path != path || self.location != location else {
      let needsLoad = changedLimit || loading || prepared?.path != path
      startPolling()
      loadTask = try? work.task {
        await settling?.value
        guard !Task.isCancelled else { return }
        if needsLoad { await self.load(reset: true) } else { await self.refresh() }
      }
      return
    }
    loadTask = try? work.task { [weak self] in
      await settling?.value
      guard !Task.isCancelled else { return }
      guard let self else { return }
      if self.location != location {
        source = DocumentResources(location: location, client: client); self.location = location
        history = []; historyIndex = -1
      } else {
        let position = await scrollPosition()
        guard !Task.isCancelled else { return }
        if let position, history.indices.contains(historyIndex) { history[historyIndex].1 = position }
      }
      if recordHistory {
        history = Array(history.prefix(historyIndex + 1)); history.append((path, 0)); historyIndex = history.count - 1
        if history.count > 256 { history.removeFirst(history.count - 256); historyIndex = history.count - 1 }
        pendingScroll = nil
      }
      self.path = path
      updateHistory()
      await load(reset: true)
      startPolling()
    }
  }
  /// Switches between the rendered page and the file's own text, and shows the current document again.
  public func setShowsSource(_ value: Bool) {
    guard value != showsSource else { return }
    showsSource = value
    clearOutline()
    guard active, path != nil else { return }
    loadTask?.cancel()
    loadTask = try? work.task { [weak self] in await self?.load(reset: false) }
  }
  /// Scrolls the Markdown page so the heading at `index` in `outline` is at the top.
  public func scrollToHeading(_ index: Int) {
    guard outline.indices.contains(index) else { return }
    activeHeading = index
    webView.evaluateJavaScript("window.frameOutlineGo && window.frameOutlineGo(\(index))", in: nil, in: .defaultClient) { _ in }
  }
  private func clearOutline() {
    if !outline.isEmpty { outline = [] }
    if activeHeading != nil { activeHeading = nil }
  }
  public func back() { go(-1) }
  public func forward() { go(1) }
  private func go(_ offset: Int) {
    let next = historyIndex + offset
    guard active, history.indices.contains(next), let location else { return }
    loadTask?.cancel()
    loadTask = try? work.task { [weak self] in
      guard let self else { return }
      let position = await scrollPosition()
      guard !Task.isCancelled else { return }
      if let position, history.indices.contains(historyIndex) { history[historyIndex].1 = position }
      historyIndex = next; path = history[next].0; pendingScroll = history[next].1
      onNavigate?(history[next].0); updateHistory()
      // App navigation acquires a fresh format plugin before displaying the target.
      if onNavigate != nil { return }
      self.location = location
      await load(reset: true)
    }
  }
  private func updateHistory() { canGoBack = historyIndex > 0; canGoForward = historyIndex + 1 < history.count }
  private func scrollPosition() async -> Double? {
    guard !Task.isCancelled, let path, let page = webView.url, page.scheme == "frame-document",
          page.host == host, page.path == "/" + path else { return nil }
    // A stopped web process can leave a JavaScript callback unanswered. Scroll history is best effort.
    let (positions, reply) = AsyncStream<Double>.makeStream()
    webView.evaluateJavaScript("window.scrollY", in: nil, in: .defaultClient) { result in
      if case .success(let value as Double) = result { reply.yield(value) }
      reply.finish()
    }
    let deadline = Task {
      try await Task.sleep(for: .milliseconds(250))
      reply.finish()
    }
    defer { deadline.cancel(); reply.finish() }
    var iterator = positions.makeAsyncIterator()
    return await iterator.next()
  }
  public func refresh() async {
    guard active else { return }
    _ = try? await work.run { [weak self] in await self?.refreshContent() }
  }
  private func refreshContent() async {
    guard active, !refreshing, let source, !loading else { return }
    let token = generation
    refreshing = true; defer { refreshing = false }
    do {
      if try await source.refresh() {
        guard active, generation == token, !Task.isCancelled else { return }
        let position = await scrollPosition()
        guard active, generation == token, !Task.isCancelled else { return }
        if let position { pendingScroll = position }
        await load(reset: false)
      }
    } catch { if active, generation == token, !Task.isCancelled { self.error = "Connection unavailable. Retry." } }
  }
  public func retry() {
    guard active else { return }
    loadTask?.cancel(); loadTask = try? work.task { [weak self] in await self?.refresh(); await self?.load(reset: false) }
  }
  private func startPolling() {
    pollTask?.cancel()
    guard active, case .remote = location else { return }
    pollTask = try? work.task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard let self else { return }
        if NSApp?.isActive == true { await refresh() }
      }
    }
  }
  private func load(reset: Bool) async {
    guard active, !Task.isCancelled, let source, let path, let location else { return }
    let token = UUID(); generation = token
    loading = true
    clearOutline()
    defer { if generation == token { loading = false } }
    do {
      if reset { try await source.begin() }
      let data = try await source.data(at: path, limit: documentLimit)
      guard !data.isEmpty else { throw BridgeError("File is empty. Retry after saving.") }
      let page = try await self.parser.page(data, extension: (path as NSString).pathExtension, referenceToken: source.host, source: showsSource,
                                            paper: .current)
      guard generation == token, !Task.isCancelled else { return }
      hasPageOutline = page.hasOutline
      prepared = (source.host, path, Data(page.html.utf8))
      for task in tasks.values { task.cancel() }; tasks.removeAll()
      error = nil
      var url = URLComponents(); url.scheme = "frame-document"; url.host = source.host; url.path = "/" + path
      guard let navigation = webView.load(URLRequest(url: url.url!)) else { throw BridgeError("Preview could not open. Retry.") }
      pendingPage = (navigation, location, path)
    } catch {
      guard generation == token, !Task.isCancelled else { return }
      self.error = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == CocoaError.fileReadNoSuchFile.rawValue
        ? "File missing." : error.localizedDescription
      if reset { pendingPage = nil; displayedPage = nil; hasPageOutline = false; webView.loadHTMLString("<style>\(DocumentHTML.theme)</style><article>No preview</article>", baseURL: nil) }
    }
  }
  public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    let key = ObjectIdentifier(urlSchemeTask)
    // A request is served only from the source whose host it names.
    guard active, let source, let url = urlSchemeTask.request.url, url.host == source.host, url.user == nil, url.password == nil,
          urlSchemeTask.request.httpMethod == "GET" || urlSchemeTask.request.httpMethod == nil
    else { urlSchemeTask.didFailWithError(BridgeError("Resource outside this folder.")); return }
    let path: String
    do { path = try DocumentResources.normalized(url.path) }
    catch { urlSchemeTask.didFailWithError(error); return }
    let prepared = self.prepared?.host == source.host ? self.prepared : nil
    let parser = self.parser, referenceToken = source.host, paper = DocumentPaper.current
    let documentLimit = self.documentLimit
    tasks[key] = try? work.task { [weak self] in
      do {
        let isDocument = AssetCompanionNames.isDocument(path) || prepared?.path == path
        let bytes: Data
        if prepared?.path == path { bytes = prepared!.data }
        else {
          let data = try await source.data(at: path, limit: isDocument ? documentLimit : DocumentResources.resourceLimit)
          if isDocument {
            bytes = Data(try await parser.page(data, extension: (path as NSString).pathExtension, referenceToken: referenceToken,
                                               paper: paper).html.utf8)
          }
          else { bytes = data }
        }
        guard !Task.isCancelled, let self, tasks[key] != nil else { return }
        let mime = isDocument ? "text/html" : UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let policy = "default-src 'none'; script-src frame-document: http: https: 'unsafe-inline' 'unsafe-eval'; style-src frame-document: http: https: 'unsafe-inline'; img-src frame-document: http: https: data: blob:; font-src frame-document: http: https: data:; media-src frame-document: http: https: blob:; connect-src frame-document: http: https: ws: wss:; frame-src 'none'; object-src 'none'; worker-src blob:; base-uri 'none'; form-action 'none'"
        // Headers and an early meta policy are both supplied; authored policies cannot relax them.
        let delivered = isDocument ? Data(("<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"" + policy + "\">").utf8) + bytes : bytes
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
          "Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""),
          "Content-Security-Policy": policy, "Cache-Control": "no-store", "Access-Control-Allow-Origin": "*",
          "X-Content-Type-Options": "nosniff"
        ])!
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(delivered); urlSchemeTask.didFinish()
        tasks.removeValue(forKey: key)
      } catch {
        guard !Task.isCancelled, let self, tasks[key] != nil else { return }
        self.error = "Some resources could not be loaded."
        urlSchemeTask.didFailWithError(error); tasks.removeValue(forKey: key)
      }
    }
  }
  public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
  }
  public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
    // Frame owns document history; WebKit's Backspace navigation bypasses file selection.
    if navigationAction.navigationType == .backForward { decisionHandler(.cancel); return }
    if url.absoluteString == "about:blank", navigationAction.targetFrame?.isMainFrame == true { decisionHandler(.allow); return }
    guard active else { decisionHandler(.cancel); return }
    if url.scheme == "frame-document", let host, url.host == host {
      if navigationAction.navigationType == .linkActivated, url.path != webView.url?.path {
        let target = String(url.path.dropFirst())
        onNavigate?(target)
        if onNavigate == nil, !AssetCompanionNames.isMedia(target), let location { show(path: target, location: location) }
        decisionHandler(.cancel); return
      }
      decisionHandler(navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
    } else {
      if navigationAction.navigationType == .linkActivated, let host,
         let block = MarkdownRenderer.copiedBlockIndex(from: url, referenceToken: host) { copyCode(block) }
      else if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
      decisionHandler(.cancel)
    }
  }
  /// Only a Markdown page from this renderer has Copy links; an HTML document that learns the host cannot use one.
  private func copyCode(_ block: Int) {
    // Only a page this renderer loaded as Markdown, which carries no script. An HTML document can
    // run script, read the token from its own address and rewrite that address, so neither is trusted.
    guard showsMarkdown, let page = webView.url else { return }
    let token = generation, figure = "document.querySelectorAll('figure.code')[\(block)]"
    // Copy owns no files. A late WebKit reply can be discarded after navigation or shutdown.
    webView.evaluateJavaScript("\(figure)?.querySelector('pre')?.textContent ?? null", in: nil, in: .defaultClient) { [weak self] result in
      guard let self, active, generation == token, webView.url == page,
            case .success(let text as String) = result else { return }
      copyToPasteboard(text)
      webView.evaluateJavaScript("(()=>{const a=\(figure)?.querySelector('.copy');if(a){clearTimeout(a.doneTimer);a.classList.add('done');a.doneTimer=setTimeout(()=>a.classList.remove('done'),1200)}return true})()", in: nil, in: .defaultClient) { _ in }
    }
  }
  public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    if let page = pendingPage, page.navigation === navigation {
      displayedPage = (page.location, page.path)
      pendingPage = nil
    }
    // Recorded once per load. The scheme handler renders by this same extension, and a page's
    // script can change the address afterwards only without a new load.
    let page = webView.url
    showsMarkdown = page?.scheme == "frame-document" && host != nil && page?.host == host
      && ["md", "markdown"].contains(page?.pathExtension.lowercased() ?? "")
  }
  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    followPaper()
    if let pendingScroll { webView.evaluateJavaScript("window.scrollTo(0,\(pendingScroll))"); self.pendingScroll = nil }
  }
  public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard let page = pendingPage, page.navigation === navigation else { return }
    pendingPage = nil
    self.error = error.localizedDescription
  }
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    pendingPage = nil; displayedPage = nil; error = "Preview stopped. Retry."
  }
  public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == Self.outlineMessage { receiveOutline(message); return }
    guard message.name == "resourceBlocked", message.frameInfo.isMainFrame else { return }
    error = "Some page content is unavailable."
  }
  /// Accepts the outline only from Frame's isolated world, for the rendered Markdown page on show.
  private func receiveOutline(_ message: WKScriptMessage) {
    guard message.world == .defaultClient, message.frameInfo.isMainFrame, showsMarkdown, !showsSource, let path, let host,
          message.frameInfo.request.url?.host == host, message.frameInfo.request.url?.path == "/" + path,
          let body = message.body as? [String: Any], let items = body["headings"] as? [[Any]] else { return }
    let headings = items.prefix(Self.outlineLimit).compactMap { item -> DocumentHeading? in
      guard item.count == 2, let level = (item[0] as? NSNumber)?.intValue, level == 2 || level == 3,
            let title = item[1] as? String else { return nil }
      return DocumentHeading(level: level, title: String(title.prefix(300)))
    }
    if headings != outline { outline = headings }
    let index = (body["active"] as? NSNumber)?.intValue
    let next = index.flatMap { headings.indices.contains($0) ? $0 : nil }
    if next != activeHeading { activeHeading = next }
  }
  static let outlineMessage = "frameOutline"
  static let outlineLimit = 300
  /// Reports the article's h2 and h3 headings and the one being read: the last whose top has passed a quarter
  /// of the way down the view, or at the end of the page the last one visible, or the one just chosen until
  /// the reader scrolls again.
  static let outlineScript = """
  (() => {
    const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(outlineMessage);
    if (!channel) return;
    let chosen = -1, queued = false, last = '';
    const headings = () => Array.from(document.querySelectorAll('article.markdown h2, article.markdown h3')).slice(0, \(outlineLimit));
    const report = () => {
      queued = false;
      const list = headings();
      const line = innerHeight * 0.25;
      let active = list.length ? 0 : -1;
      list.forEach((h, i) => { if (h.getBoundingClientRect().top <= line) active = i; });
      if (list.length && scrollY + innerHeight >= document.documentElement.scrollHeight - 4) {
        list.forEach((h, i) => { if (h.getBoundingClientRect().top < innerHeight) active = Math.max(active, i); });
      }
      if (chosen >= 0 && chosen < list.length) active = chosen;
      const items = list.map(h => [h.tagName === 'H3' ? 3 : 2, (h.textContent || '').trim()]);
      const text = JSON.stringify([items, active]);
      if (text !== last) { last = text; channel.postMessage({ headings: items, active }); }
    };
    // A timer rather than an animation frame, which WebKit holds back while the view is not on screen.
    const schedule = () => { if (!queued) { queued = true; setTimeout(report, 60); } };
    const release = () => { chosen = -1; };
    addEventListener('scroll', schedule, { passive: true });
    addEventListener('resize', schedule);
    addEventListener('load', schedule);
    for (const name of ['wheel', 'keydown', 'mousedown']) addEventListener(name, release, { passive: true, capture: true });
    window.frameOutlineGo = (index) => {
      const target = headings()[index];
      if (!target) return false;
      chosen = index;
      scrollTo({ top: Math.max(0, target.getBoundingClientRect().top + scrollY - 16), behavior: 'auto' });
      schedule();
      return true;
    };
    schedule();
  })();
  """
}

@MainActor private final class WeakDocumentScheme: NSObject, WKURLSchemeHandler {
  weak var owner: DocumentRenderer?
  init(_ owner: DocumentRenderer) { self.owner = owner }
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) { owner?.webView(webView, start: urlSchemeTask) }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { owner?.webView(webView, stop: urlSchemeTask) }
}

@MainActor private final class WeakDocumentMessage: NSObject, WKScriptMessageHandler {
  weak var owner: DocumentRenderer?
  init(_ owner: DocumentRenderer) { self.owner = owner }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.userContentController(userContentController, didReceive: message)
  }
}

/// One entry of a Markdown page's outline.
public struct DocumentHeading: Equatable, Sendable {
  public let level: Int
  public let title: String
  public init(level: Int, title: String) {
    self.level = level
    self.title = title
  }
}
