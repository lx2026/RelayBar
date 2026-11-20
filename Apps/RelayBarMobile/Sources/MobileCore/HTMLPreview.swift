import Foundation
import Network
import RelayWebRoutes
import WebKit

/// Isolated from every service browser, including the host's persistent data store.
@MainActor package final class HTMLPreview: NSObject, WKNavigationDelegate, WKUIDelegate {
  package let web: WKWebView
  package let handler: DocumentSchemeHandler
  private let demoProxy: SOCKSProxy?
  private let host: String?
  private let internet: Bool
  package init(path: String, html: String, files: (any RemoteFiles)?, scripts: Bool, internet: Bool, host: String? = nil) async throws
  {
    self.host = host
    self.internet = internet
    let sources = internet ? "relay-document: https: http:" : "relay-document:"
    let csp =
      "default-src 'none'; img-src data: \(sources); style-src 'unsafe-inline' \(sources); font-src data: \(sources); script-src 'unsafe-inline' \(sources); media-src \(sources); connect-src \(sources); frame-src 'none'; form-action 'none'; base-uri 'none'; worker-src 'none'; webrtc 'block'"
    handler = DocumentSchemeHandler(
      // As on the Mac: a leading doctype keeps the page out of quirks mode once the policy precedes it.
      path: path,
      html: "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
        + html,
      files: files, folderOnly: true)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    if let demo = files as? DemoHost {
      let server = try await SOCKSProxy.start(privateName: DemoHost.referenceHost, opener: demo)
      server.setDestinations([ProxyDestination(host: DemoHost.referenceHost, port: 80)])
      var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1",
        port: .init(rawValue: server.port)!))
      proxy.applyCredential(username: server.username, password: server.password)
      proxy.allowFailover = false
      config.websiteDataStore.proxyConfigurations = [proxy]
      demoProxy = server
    } else {
      demoProxy = nil
    }
    // Enforce the engine restriction even in a newly created, empty frame.
    config.defaultWebpagePreferences.isLockdownModeEnabled = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.userContentController.addUserScript(WKUserScript(
      source: Self.disableRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    config.defaultWebpagePreferences.allowsContentJavaScript = scripts
    config.setURLSchemeHandler(handler, forURLScheme: "relay-document")
    web = WKWebView(frame: .zero, configuration: config)
    super.init()
    web.navigationDelegate = self
    web.uiDelegate = self
  }
  private static let disableRTC = """
    (() => {
      function disable(object, key) {
        Object.defineProperty(object, key, {
          value: undefined, writable: false, configurable: false
        });
      }
      for (const name of Object.getOwnPropertyNames(globalThis)) {
        if (/^(?:webkit|moz)?RTC/i.test(name)) disable(globalThis, name);
      }
      if (globalThis.MediaDevices) {
        for (const name of ['getUserMedia', 'getDisplayMedia']) disable(MediaDevices.prototype, name);
      }
      for (const name of ['mediaDevices', 'getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia']) {
        disable(Navigator.prototype, name);
      }
    })();
    """
  package func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
    initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision
  { .deny }

  deinit { if let demoProxy { Task { await demoProxy.stop() } } }
  package func load() async throws {
    let source =
      internet
      ? try LoopbackRules.rules([], blockPrivateNames: true, profileHost: host)
      : #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^relay-document:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]"#
    guard
      let list = try await WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: internet ? "reader-internet-v3" : "reader-folder-v1",
        encodedContentRuleList: String(source))
    else { throw URLError(.cannotLoadFromNetwork) }
    try Task.checkCancellation()
    web.configuration.userContentController.add(list)
    web.load(URLRequest(url: handler.scheme.mainURL))
  }
  package func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async
    -> WKNavigationActionPolicy
  {
    action.targetFrame?.isMainFrame == true && action.request.url == handler.scheme.mainURL
      ? .allow : .cancel
  }
}
