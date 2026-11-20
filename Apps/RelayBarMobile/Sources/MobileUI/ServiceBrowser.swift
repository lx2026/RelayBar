import Composition
import HouseStyle
import ImageIO
import MobileCore
import RelayWebRoutes
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor final class ServicePages: ObservableObject {
  private var pages: [ServiceAddress: ServiceBrowser] = [:]
  @Published var revision = 0
  func page(_ address: ServiceAddress) -> ServiceBrowser {
    if let page = pages[address] { return page }
    let page = ServiceBrowser()
    page.pictureSaved = { [weak self] in self?.revision += 1 }
    pages[address] = page
    return page
  }
  func preview(_ address: ServiceAddress) -> ServicePreview? {
    pages.first { $0.key.saved == address }?.value.preview
  }
  func close(_ address: ServiceAddress) {
    for key in pages.keys.filter({ $0.saved == address }) { pages.removeValue(forKey: key)?.stop() }
  }
  func suspend() { for page in pages.values { page.stop() } }
}

@MainActor final class ServiceBrowser: NSObject, ObservableObject, WKNavigationDelegate {
  @Published var web: WKWebView?
  @Published var offer = false
  @Published var reason = ""
  @Published var route: WebRoute = .privateName
  var preview: ServicePreview?
  let review = ServiceReview()
  private var allowedOnce: Destination?
  private var networkLease: (HostNetwork, UUID)?
  private var trust: PrivateServiceTrust?
  var redirect: ((ServiceAddress) -> Void)?
  private var lease: WebLease?
  private var pool: WebRoutePool?
  private(set) var teardown: Task<Void, Never>?
  private var revision = UUID()
  private var profile: Profile?
  private var address: ServiceAddress?
  private var remembered: Bool?
  private var compatible = false
  private var responseStatus: Int?
  private var target: URL?
  private var labeller: ServiceLabeller?
  private var titleTask: Task<Void, Never>?
  private var saveTitle: ((String) -> Void)?

  private var pictureKey: CacheIdentity?
  private var pictureCache: DocumentCache?
  var pictureSaved: (() -> Void)?
  private var loadedGeneration: Int?
  private func capturePicture() {
    guard let view = web, !view.isLoading, view.url != nil,
      responseStatus.map({ $0 < 400 }) ?? true,
      let key = pictureKey, let cache = pictureCache
    else { return }
    let routeName =
      route == .direct ? "direct" : route == .localhost ? "as localhost" : "private name"
    let snapshot = WKSnapshotConfiguration()
    snapshot.snapshotWidth = 240
    view.takeSnapshot(with: snapshot) { [weak self] image, _ in
      guard let self, let image else { return }
      #if os(iOS)
        let cg = image.cgImage
      #else
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      #endif
      guard let cg else { return }
      preview = ServicePreview(image: cg, route: routeName)
      let bytes = NSMutableData()
      guard
        let output = CGImageDestinationCreateWithData(
          bytes, UTType.png.identifier as CFString, 1, nil)
      else { return }
      CGImageDestinationAddImage(output, cg, nil)
      guard CGImageDestinationFinalize(output) else { return }
      let data = bytes as Data
      Task {
        try? await cache.saveWebsitePicture(data, key: key)
        pictureSaved?()
      }
    }
  }
  func hide() {
    capturePicture()
    if route == .localhost || networkLease != nil || trust != nil || review.prompt != nil
      || web == nil
    {
      stop()
    }
  }
  func stop() {
    review.answer(.refuse)
    if let (network, id) = networkLease { Task { await network.close(id) } }
    allowedOnce = nil
    networkLease = nil
    trust = nil
    revision = UUID()
    loadedGeneration = nil
    titleTask?.cancel()
    titleTask = nil
    web?.stopLoading()
    web?.navigationDelegate = nil
    web?.customUserAgent = nil
    web = nil
    offer = false
    saveTitle = nil
    if let lease, let pool { teardown = Task { await pool.close(lease) } }
    lease = nil
  }
  func start(
    core: MobileComposition, profile: Profile, address: ServiceAddress,
    generation: Int, routes: [WebRoute], requested: WebRoute?, remembered: Bool?,
    saveTitle: @escaping (String) -> Void
  ) async {
    compatible = routes.contains(.localhost) && address.scheme == "http"
    self.remembered = remembered
    if web != nil, requested == nil, loadedGeneration == generation, route != .localhost { return }
    stop()
    loadedGeneration = generation
    let current = revision
    await teardown?.value
    guard current == revision, !Task.isCancelled else { return }
    guard let opener = core.runtime.service(WebUpstream.self, realm: profile.realm),
      routes.contains(.privateName)
    else {
      reason = "Waiting for the host connection…"
      return
    }
    self.profile = profile
    self.address = address
    pictureCache = core.cache
    pictureKey = core.websiteKey(address, host: profile)
    self.labeller = core.runtime.service(ServiceLabellers.self, realm: profile.realm)?.entries.first
    self.saveTitle = saveTitle
    reason = ""
    do {
      guard let prefs = core.runtime.service(Profiles.self) else { throw CancellationError() }
      if let name = address.destination {
        guard let network = core.runtime.service(NetworkAccess.self, realm: profile.realm) else {
          throw CompositionError("Turn on " + networkPlugin.title)
        }
        let endpoint = Destination(name: name, port: address.port)
        let (id, view) = try await network.open(address) { [weak self] _ in
          guard let self else { return .refuse }
          return await self.approve(endpoint, profile: profile, prefs: prefs, revision: current)
        }
        guard revision == current, !Task.isCancelled else {
          await network.close(id)
          return
        }
        networkLease = (network, id)
        route = .privateName
        view.navigationDelegate = self
        web = view
        load()
        return
      }
      if address.scheme == "https" {
        trust = PrivateServiceTrust(profile: profile, port: address.port, preferences: prefs)
      }
      let acquired = try await core.routes.open(
        profile: profile, port: address.port, opener: opener)
      guard current == revision, !Task.isCancelled else {
        await core.routes.close(acquired)
        return
      }
      pool = core.routes
      lease = acquired
      let reachable =
        address.scheme == "http" && requested == nil && routes.contains(.direct)
        && !(opener is DemoHost)
      let direct = reachable ? await directReachable(host: profile.host, port: address.port) : false
      guard current == revision, !Task.isCancelled else { return }
      route = requested ?? ServiceChoice.initial(reachable: direct)
      let view = acquired.makeView()
      if route == .localhost {
        guard compatible else { throw CompositionError("Localhost Compatibility is unavailable.") }
        try await core.routes.authorize(acquired, web: view)
      } else {
        try await LoopbackRules.install(on: view, ports: [])
      }
      guard current == revision, !Task.isCancelled else { return }
      view.navigationDelegate = self
      web = view
      load()
    } catch {
      guard current == revision else { return }
      stop()
      reason = error.localizedDescription
    }
  }
  private func approve(
    _ endpoint: Destination, profile: Profile, prefs: PreferenceStore<Preferences>, revision: UUID
  ) async -> ProxyApproval {
    guard !Task.isCancelled, self.revision == revision,
      prefs.value.enabled(networkPlugin, host: profile.id)
    else { return .refuse }
    if allowedOnce == endpoint { return .allowOnce }
    if prefs.value.destinations?[profile.id]?.contains(endpoint) == true {
      return .allowAndRemember
    }
    let decision = await review.ask(.destination(endpoint))
    guard !Task.isCancelled, self.revision == revision,
      prefs.value.enabled(networkPlugin, host: profile.id)
    else { return .refuse }
    switch decision {
    case .always:
      do {
        try prefs.update { $0.remember(endpoint, host: profile.id) }
        return .allowAndRemember
      } catch {
        reason = error.localizedDescription
        return .refuse
      }
    case .once:
      allowedOnce = endpoint
      return .allowOnce
    default: return .refuse
    }
  }
  func webView(_ view: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
    -> (URLSession.AuthChallengeDisposition, URLCredential?)
  {
    guard view === web, let trust else { return (.performDefaultHandling, nil) }
    return await trust.answer(challenge) { leaf, previous in
      let answer = await review.ask(.certificate(trust.endpoint, leaf, previous: previous))
      guard view === web else { return false }
      if previous != nil {
        reason = "The service certificate changed. Retry to review it."
        if answer == .forget {
          do {
            try trust.preferences.update { prefs in
              if prefs.certificates?[trust.profile.id]?[trust.endpoint] == previous {
                prefs.pin(nil, host: trust.profile.id, endpoint: trust.endpoint)
              }
            }
          } catch { reason = error.localizedDescription }
        }
      }
      return answer == .once
    }
  }
  func load() {
    guard let profile, let address, let web else { return }
    let host =
      route == .localhost ? "localhost" : route == .direct ? profile.host : profile.privateName
    guard let url = address.url(host: host) else {
      reason = "Invalid service address."
      return
    }
    target = url
    reason = ""
    web.load(URLRequest(url: url))
  }
  func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async
    -> WKNavigationActionPolicy
  {
    guard view === web else { return .cancel }
    guard action.targetFrame?.isMainFrame != false else { return .allow }
    guard let url = action.request.url, let target else { return .cancel }
    if url.host?.lowercased() != target.host?.lowercased() || url.scheme != target.scheme
      || (url.port ?? (url.scheme == "https" ? 443 : 80))
        != (target.port ?? (target.scheme == "https" ? 443 : 80))
    {
      if ServiceChoice.offer(
        route: route, enabled: compatible, remembered: remembered, redirect: url.host)
      {
        offer = true
      } else if route != .localhost, let profile,
        let next = ServiceAddress.external(url.absoluteString, profile: profile), let redirect
      {
        redirect(next)
      } else {
        reason =
          url.scheme == "http"
          ? "Use HTTPS for a full destination name." : "The service redirected outside its address."
      }
      return .cancel
    }
    return .allow
  }
  func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse) async
    -> WKNavigationResponsePolicy
  {
    if view === web, response.isForMainFrame {
      responseStatus = (response.response as? HTTPURLResponse)?.statusCode
    }
    return .allow
  }
  func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
    guard view === web else { return }
    if let status = responseStatus, status >= 400 {
      Task {
        let detail =
          (try? await view.evaluateJavaScript("document.body.innerText.slice(0, 512)") as? String)
          ?? ""
        guard view === web else { return }
        reason =
          "HTTP \(status) · " + HTTPURLResponse.localizedString(forStatusCode: status)
          + (detail.isEmpty ? "" : "\n" + detail)
        offer = ServiceChoice.offer(
          route: route, enabled: compatible, remembered: remembered, status: status, detail: detail)
      }
      return
    }
    guard let labeller, let url = target, titleTask == nil else { return }
    let proxies = view.configuration.websiteDataStore.proxyConfigurations
    titleTask = Task {
      if let title = await labeller.read(
        url, proxies, route == .localhost ? view.customUserAgent : nil), !Task.isCancelled
      {
        saveTitle?(title)
      }
    }
  }
  func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
    guard view === web else { return }
    if view.url != nil { view.reload() } else { load() }
  }
  func webView(
    _ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    guard view === web, !Self.cancelled(error) else { return }
    if !reason.isEmpty { return }
    if route == .direct {
      route = .privateName
      load()
    } else {
      reason = error.localizedDescription
    }
  }
  func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if view === web, reason.isEmpty, !Self.cancelled(error) { reason = error.localizedDescription }
  }
  private static func cancelled(_ error: Error) -> Bool {
    let e = error as NSError
    return (e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled)
      || (e.domain == "WebKitErrorDomain" && e.code == 102)
  }
}

#if os(iOS)
  struct ServiceWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ view: WKWebView, context: Context) {}
  }
#else
  struct ServiceWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
  }
#endif

struct ServicePage: View {
  let core: MobileComposition
  let profile: Profile
  let address: ServiceAddress
  let routes: [WebRoute]
  let visible: Bool
  @ObservedObject var browser: ServiceBrowser
  @ObservedObject var prefs: PreferenceStore<Preferences>
  @ObservedObject var upstream: ServicePort<any RouteStreamOpener>
  var redirect: ((ServiceAddress) -> Void)? = nil
  let back: () -> Void
  let tabs: () -> Void
  let go: () -> Void
  @Environment(\.scenePhase) private var phase
  @State private var request: WebRoute?
  @State private var attempt = UUID()
  @Environment(\.padReader) private var pad
  @Environment(\.closePane) private var closePane
  @State private var finding = false
  @State private var query = ""
  var title: String {
    address.destination ?? prefs.value.serviceTitles?[profile.id]?[address.port]
      ?? ":\(address.port)"
  }
  var body: some View {
    VStack(spacing: 0) {
      if pad {
        PadServiceHeader(
          title: title, host: profile.host, port: address.port, back: { browser.web?.goBack() },
          forward: { browser.web?.goForward() }, reload: { browser.web?.reload() },
          close: { if let closePane { closePane.action() } else { back() } },
          route: browser.route == .direct
            ? "Direct" : browser.route == .localhost ? "Localhost" : "Private name")
      }
      if finding {
        HStack {
          TextField("Find on page", text: $query).onSubmit(find)
          Button("Next", action: find)
          Button("Done") { finding = false }
        }.padding()
      }
      if !browser.reason.isEmpty {
        VStack {
          Text(browser.reason)
          Button("Retry") {
            browser.stop()
            attempt = UUID()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let web = browser.web {
        ServiceWebView(web: web).id(ObjectIdentifier(web))
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.overlay(alignment: .bottom) {
      if !pad {
        ServiceBar(
          host: profile.host, port: address.port,
          count: prefs.value.serviceTabs?.values.reduce(0) { $0 + $1.count } ?? 0,
          state: core.states.values[profile.id] ?? .idle,
          back: { if let web = browser.web, web.canGoBack { web.goBack() } else { back() } },
          go: go,
          reload: {
            if browser.reason.isEmpty, let web = browser.web {
              web.reload()
            } else {
              browser.stop()
              attempt = UUID()
            }
          },
          tabs: tabs
        ) {
          Button("Forward") { browser.web?.goForward() }.disabled(browser.web?.canGoForward != true)
          Button("Find on Page") { finding = true }
          Button("Copy Address") {
            let url = browser.web?.url?.absoluteString
            #if os(iOS)
              UIPasteboard.general.string = url
            #else
              if let url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
              }
            #endif
          }
          if address.destination == nil, routes.contains(.localhost), address.scheme == "http" {
            if browser.route == .localhost {
              Button("Use Private Name") { choose(false) }
            } else {
              Button("Open as Localhost") { browser.offer = true }
            }
          }
          if core.runtime.service(PinnedServices.self, realm: profile.realm) == true {
            let pinned = prefs.value.pinnedServices?[profile.id]?.contains(address.saved) == true
            Button(pinned ? "Unpin Website" : "Pin Website") {
              do {
                try prefs.update { value in
                  var pins = value.pinnedServices ?? [:]
                  if pinned {
                    pins[profile.id]?.removeAll { $0 == address.saved }
                  } else {
                    pins[profile.id, default: []].append(address.saved)
                  }
                  value.pinnedServices = pins
                }
              } catch { browser.reason = error.localizedDescription }
            }
          }
        }.serviceFade()
      }
    }
    .task(
      id: RunID(
        active: phase == .active && visible, generation: upstream.generation, routes: routes,
        attempt: attempt)
    ) {
      guard phase == .active else {
        request = nil
        browser.stop()
        return
      }
      guard visible else {
        request = nil
        browser.hide()
        return
      }
      browser.redirect = prefs.value.enabled(networkPlugin, host: profile.id) ? redirect : nil
      await browser.start(
        core: core, profile: profile, address: address, generation: upstream.generation,
        routes: routes, requested: request,
        remembered: prefs.value.localhostChoices?[profile.id]?[address.port]
      ) { text in
        // Titles are keyed by the host's port, so another machine's page must not label it.
        guard address.destination == nil,
          core.runtime.service(ServiceLabellers.self, realm: profile.realm)?.entries.isEmpty
            == false
        else { return }
        do {
          try prefs.update { value in
            var titles = value.serviceTitles ?? [:]
            titles[profile.id, default: [:]][address.port] = text
            value.serviceTitles = titles
          }
        } catch { browser.reason = error.localizedDescription }
      }
    }.onDisappear {
      request = nil
      browser.hide()
    }
    .modifier(ServiceReviewPanel(review: browser.review, host: profile.host))
    .bottomPanel(shown: browser.offer, fraction: 0.65) {
      LocalhostOffer(
        host: profile.host, title: title, accept: { choose(true) }, decline: { choose(false) }
      )

    }
  }
  private struct RunID: Equatable {
    let active: Bool
    let generation: Int
    let routes: [WebRoute]
    let attempt: UUID
  }
  private func find() {
    if !query.isEmpty { browser.web?.find(query, configuration: WKFindConfiguration()) { _ in } }
  }
  private func choose(_ exact: Bool) {
    browser.offer = false
    do {
      try prefs.update { value in
        var choices = value.localhostChoices ?? [:]
        choices[profile.id, default: [:]][address.port] = exact
        value.localhostChoices = choices
      }
      request = exact ? .localhost : .privateName
      attempt = UUID()
    } catch { browser.reason = error.localizedDescription }
  }
}

private struct ServiceReviewPanel: ViewModifier {
  @ObservedObject var review: ServiceReview
  let host: String
  func body(content: Content) -> some View {
    content.bottomPanel(shown: review.prompt != nil, fraction: 0.7) {
      if let prompt = review.prompt {
        ApprovalSheet(prompt: prompt, host: host, answer: review.answer)
      }
    }
  }
}
