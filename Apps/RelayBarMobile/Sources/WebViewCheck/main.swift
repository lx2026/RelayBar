#if os(macOS)
  import AppKit
  import CompositionFixtures
  import MobileCore
  import WebKit
  import RelayWebRoutes

  @MainActor final class Navigation: NSObject, WKNavigationDelegate {
    var trust:
      ((URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    func webView(_ web: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (
      URLSession.AuthChallengeDisposition, URLCredential?
    ) {
      await trust?(challenge) ?? (.performDefaultHandling, nil)
    }
    var status = 0
    var loaded = false
    var failure: Error?
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async
      -> WKNavigationResponsePolicy
    {
      status = (response.response as? HTTPURLResponse)?.statusCode ?? 0
      return .allow
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) { failure = error }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      failure = error
    }
    func load(_ url: URL, in web: WKWebView) async throws {
      web.navigationDelegate = self
      web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
      let deadline = ContinuousClock.now + .seconds(12)
      while !loaded {
        if let failure { throw failure }
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  @MainActor func check(profile: Profile, pool: WebRoutePool) async throws {
    let reservation = try await LocalhostGate.start(port: 0)
    let notebookPort = reservation.port
    await reservation.stop()
    let demo = try DemoHost(notebookPort: notebookPort)
    let window = QuietWindow(size: NSSize(width: 390, height: 640))
    defer { window.contentView = nil }
    for mode in [0, 1] {
      let port: UInt16 = mode == 0 ? 6006 : notebookPort
      let lease = try await pool.open(profile: profile, port: port, opener: demo)
      do {
        let view = lease.makeView()
        window.contentView = view
        if mode == 1 {
          try await pool.authorize(lease, web: view)
        } else {
          try await LoopbackRules.install(on: view, ports: [])
        }
        let navigation = Navigation()
        let url = ServiceAddress(port: port).url(
          host: mode == 0 ? profile.privateName : "localhost")!
        try await navigation.load(url, in: view)
        let script =
          mode == 0
          ? "isSecureContext && document.title === 'Run monitor'" : "document.title === 'Notebooks'"
        let matches = try await view.evaluateJavaScript(script) as? Bool == true
        results[mode] =
          navigation.status == 200 && matches && !window.isVisible && !window.isKeyWindow
        if mode == 1 {
          let config = WKWebViewConfiguration()
          config.websiteDataStore = .nonPersistent()
          let other = WKWebView(frame: .zero, configuration: config)
          window.contentView = other
          let otherNavigation = Navigation()
          try await otherNavigation.load(url, in: other)
          results[2] = otherNavigation.status == 403 && !window.isVisible && !window.isKeyWindow
          window.contentView = nil
          for allowed in [false, true] {
            let html = """
              <title>Checking</title><script>
              const blocked = u => fetch(u,{mode:'no-cors'}).then(()=>false,()=>true);
              Promise.all([blocked('http://localhost:\(port)/'),blocked('http://\(profile.privateName):\(port)/')])
                .then(r => document.title = r.every(Boolean) ? 'Isolated' : 'Accessible');
              </script>
              """
            let page = try await HTMLPreview(
              path: DemoHost.folder + "/check.html", html: html, files: nil, scripts: true,
              internet: allowed)
            try await page.load()
            let until = ContinuousClock.now + .seconds(8)
            while page.web.title != "Isolated", ContinuousClock.now < until {
              try await Task.sleep(for: .milliseconds(20))
            }
            let agent =
              try await page.web.evaluateJavaScript("navigator.userAgent") as? String ?? ""
            let jar = await page.web.configuration.websiteDataStore.httpCookieStore.allCookies()
            results[allowed ? 4 : 3] =
              page.web.title == "Isolated" && !agent.contains("RelayBar/")
              && jar.isEmpty && !page.web.configuration.websiteDataStore.isPersistent
              && page.web.configuration.websiteDataStore.proxyConfigurations.isEmpty
              && page.web.window == nil
          }
        }
      } catch { print("Web view check: " + error.localizedDescription) }
      window.contentView = nil
      await pool.close(lease)
    }
  }

  @MainActor func checkPreviewRTC(internet: Bool) async throws -> Bool {
    guard let port = ProcessInfo.processInfo.environment["RELAY_RTC_PORT"].flatMap(UInt16.init)
    else { throw URLError(.badURL) }
    let page = try await HTMLPreview(path: "/rtc.html", html: """
      <body><script>
      function blocked(realm) {
        const Peer = realm.RTCPeerConnection || realm.webkitRTCPeerConnection;
        try {
          const peer = new Peer({iceServers: [{urls: 'turn:127.0.0.1:\(port)?transport=tcp',
            username: 'fixture', credential: 'fixture'}]});
          peer.close();
          return false;
        } catch {
          return Peer === undefined && !realm.RTCDataChannel && !realm.RTCRtpSender
            && !realm.RTCRtpReceiver && !realm.navigator.mediaDevices?.getUserMedia;
        }
      }
      const child = document.createElement('iframe');
      document.body.append(child);
      const mainBlocked = blocked(window);
      const childBlocked = blocked(child.contentWindow);
      document.title = mainBlocked && childBlocked ? 'Blocked' : 'Exposed';
      </script>
      """, files: nil, scripts: true, internet: internet)
    try await page.load()
    let deadline = ContinuousClock.now + .seconds(8)
    while page.web.title != "Blocked", page.web.title != "Exposed", ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    guard page.web.title == "Blocked", page.web.window == nil else { return false }
    // The engine setting can hide RTC on its own. Check that the page-world user
    // script also ran and locked the capture entry point before any page script.
    return try await page.web.evaluateJavaScript("""
      Object.getOwnPropertyDescriptor(Navigator.prototype, 'mediaDevices')?.configurable === false
      """) as? Bool == true
  }

  @MainActor func checkDestination() async throws -> Bool {
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let demo = try DemoHost()
    let core = try MobileComposition(
      directory: root, cache: root.appending(path: "cache"), keys: DemoKeys()
    ) { _, _, _ in demo }
    let host = try await demo.install(in: core)
    let prefs = core.runtime.service(Profiles.self)!
    try prefs.update { $0.set(networkPlugin, for: host.id, enabled: true) }
    core.runtime.service(Demand.self)?.show(host.id, in: UUID())
    await core.runtime.settled()
    guard let service = core.runtime.service(NetworkAccess.self, realm: host.realm),
      let address = ServiceAddress.external("http://dashboard:6006/", profile: host),
      let url = address.url(host: host.host)
    else { throw URLError(.unsupportedURL) }
    let (id, view) = try await service.open(address) { dest in
      dest == ProxyDestination(host: "dashboard", port: 6006) ? .allowOnce : .refuse
    }
    let window = QuietWindow(size: NSSize(width: 390, height: 600))
    window.contentView = view
    let nav = Navigation()
    do { try await nav.load(url, in: view) } catch {
      print("Destination check: " + error.localizedDescription)
    }
    let loaded = view.title == "Run monitor" && !window.isVisible
    window.contentView = nil
    await service.close(id)
    await core.runtime.shutdown()
    return loaded
  }

  QuietWindow.prepareTestProcess()
  let profile = Profile(host: "web-check.invalid", account: "reader")
  var results = Array(repeating: false, count: 10)
  do { try await check(profile: profile, pool: WebRoutePool()) } catch {
    print("Web view check: " + error.localizedDescription)
  }
  do { (results[5], results[6]) = try await checkTLS(profile) } catch {
    print("TLS fixture: " + error.localizedDescription)
  }
  do { results[7] = try await checkDestination() } catch {
    print("Destination check: " + error.localizedDescription)
  }
  for allowed in [false, true] {
    do { results[allowed ? 9 : 8] = try await checkPreviewRTC(internet: allowed) } catch {
      print("Preview RTC check: " + error.localizedDescription)
    }
  }
  for (index, fact) in [
    "Private name through SOCKS is a secure context", "Exact localhost loads with its token",
    "Second web view without token is refused",
    "HTML preview blocks gate and private service",
    "Internet-enabled HTML preview still blocks gate and private service",
    "Approved private TLS loads a subresource and web socket",
    "Replaced private TLS certificate is refused",
    "Approved short destination opens through the host",
    "Preview blocks WebRTC in page and iframe (internet off)",
    "Preview blocks WebRTC in page and iframe (internet on)",
  ].enumerated() {
    print((results[index] ? "PASS " : "FAIL ") + fact)
  }
  try await removeTestStore(profile.id)
  exit(results.allSatisfy { $0 } ? EXIT_SUCCESS : EXIT_FAILURE)
#endif
