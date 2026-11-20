import Foundation
import Testing
import WebKit

@testable import MobileCore

@Test func serviceRouteChoice() {
  #expect(ServiceChoice.initial(reachable: true) == .direct)
  #expect(ServiceChoice.initial(reachable: false) == .privateName)
  for consent: Bool? in [nil, true, false] {
    #expect(
      ServiceChoice.offer(
        route: .privateName, enabled: true, remembered: consent, status: 403,
        detail: "Blocking non-local Host") == (consent != false))
    #expect(
      ServiceChoice.offer(
        route: .privateName, enabled: true, remembered: consent, redirect: "localhost")
        == (consent != false))
  }
  #expect(
    !ServiceChoice.offer(
      route: .privateName, enabled: false, remembered: true, status: 403,
      detail: "Blocking non-local Host"))
  #expect(!ServiceChoice.offer(route: .privateName, enabled: true, remembered: nil, status: 404))
  #expect(
    !ServiceChoice.offer(
      route: .privateName, enabled: true, remembered: nil, status: 403, detail: "Sign in first"))
  #expect(
    !ServiceChoice.offer(
      route: .direct, enabled: true, remembered: nil, status: 403, detail: "Blocking non-local Host"
    ))
}

@Test func serviceResolversAndSavedAddresses() throws {
  let host = Profile(host: "studio", account: "reader")
  for (kind, input) in [
    ("port", "8080"), ("port", ":8080"), ("host-port", "studio:8080"),
    ("address", "http://studio:8080"), ("address", "http://localhost:8080"),
  ] {
    #expect(ServiceAddress.parse(input, profile: host, kind: kind) == ServiceAddress(port: 8080))
  }
  #expect(
    ServiceAddress.parse("https://studio/a%20b", profile: host, kind: "address")
      == ServiceAddress(port: 443, path: "/a%20b", scheme: "https"))
  for invalid in [
    "http://u:p@studio", "file://studio/file", "http://other:80", "http://studio:99999",
  ] {
    #expect(ServiceAddress.parse(invalid, profile: host, kind: "address") == nil)
  }
  let transient = try #require(
    ServiceAddress.parse("http://studio:8888/?key=temporary#top", profile: host, kind: "address"))
  #expect(transient.url(host: "studio")?.query == "key=temporary")
  #expect(transient.saved.path == "/")
  var prefs = Preferences()
  prefs.serviceTabs = [host.id: [transient.saved]]
  let bytes = try JSONEncoder().encode(prefs)
  #expect(try JSONDecoder().decode(Preferences.self, from: bytes).serviceTabs == prefs.serviceTabs)
  let row = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(ServiceAddress(port: 8888)))
      as? [String: Any])
  #expect(Set(row.keys) == ["scheme", "port", "path"])
}

@Test func loopbackRuleDestinations() throws {
  let json = try LoopbackRules.rules([8080])
  let rules = try #require(
    JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]])
  func blocked(_ url: String) -> Bool {
    rules.filter {
      url.range(of: $0["trigger"]!["url-filter"]!, options: [.regularExpression, .caseInsensitive])
        != nil
    }
    .last?["action"]?["type"] == "block"
  }
  for host in ["localhost", "127.0.0.1", "[::1]"] {
    #expect(!blocked("http://" + host + ":8080/"))
    #expect(blocked("ws://" + host + ":8081/"))
    #expect(blocked("http://" + host + "/"))
  }
  #expect(blocked("http://localhost.:8080/"))
  #expect(blocked("http://127.0.0.2:8080/"))
  #expect(blocked("http://user@localhost:8081/path"))
  #expect(!blocked("https://service.example/"))
}

#if os(macOS)
  @Test @MainActor func exactPageGrantLifetime() async throws {
    QuietWindow.prepareTestProcess()
    let profile = Profile(host: "studio", account: "reader")
    let pool = WebRoutePool()
    let port = try loopbackPort()
    var prior = ""
    for _ in 0..<2 {
      let lease = try await pool.open(profile: profile, port: port, opener: DemoHost())
      let web = lease.makeView()
      do {
        try await pool.authorize(lease, web: web)
        let fresh = lease.token != nil && lease.token?.value != prior
        #expect(fresh)
        prior = lease.token?.value ?? ""
        let carriesToken = web.customUserAgent?.contains(prior) == true
        #expect(carriesToken)
        let cookies = await lease.store.httpCookieStore.allCookies()
        let sessionCookie = cookies.contains {
          $0.isHTTPOnly && $0.isSessionOnly && $0.value == prior
        }
        #expect(sessionCookie)
        #expect(pool.registry.servedPorts(for: profile.id) == [port])
      } catch {
        await pool.close(lease)
        throw error
      }
      await pool.close(lease)
      let revoked = lease.token == nil && web.customUserAgent?.contains(prior) != true
      #expect(revoked)
      let clean = await lease.store.httpCookieStore.allCookies().allSatisfy { $0.value != prior }
      #expect(clean)
      #expect(pool.registry.servedPorts(for: profile.id).isEmpty)
    }
    try await removeTestStore(profile.id)
  }
#endif

@Test @MainActor func registeredLocationsAndPluginOverrides() async throws {
  let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let demo = try DemoHost()
  let core = try MobileComposition(directory: root, cache: root.appending(path: "cache")) {
    _, _, _ in demo
  }
  let host = try await demo.install(in: core)
  core.runtime.service(Demand.self)?.show(host.id, in: UUID())
  await core.runtime.settled()
  do {
    let prefs = try #require(core.runtime.service(Profiles.self))
    let registry = try #require(core.runtime.service(Locations.self, realm: host.realm))
    func resolve(_ text: String) -> [Location] {
      LocationResolver.candidates(text, resolvers: registry.entries, hosts: prefs.value.hosts)
    }
    #expect(resolve("report.md").contains(.path("report.md")))
    #expect(resolve("report.md").contains(.host("report.md")))
    #expect(resolve(":8888") == [.service(.init(port: 8888))])
    #expect(resolve("Notebooks") == [.service(.init(port: 8888)), .host("Notebooks")])
    #expect(resolve("poster-studio") == [.profile(host)])
    #expect(resolve("poster-studio:6006") == [.service(.init(port: 6006))])
    #expect(resolve("http://poster-studio:6006/a") == [.service(.init(port: 6006, path: "/a"))])
    let routes = try #require(core.runtime.service(WebRoutes.self, realm: host.realm))
    #expect(Set(routes.entries) == [.direct, .privateName, .localhost])
    try prefs.update {
      $0.set(localhostPlugin, for: host.id, enabled: false)
      $0.set(pinsPlugin, for: host.id, enabled: false)
      $0.set(labelsPlugin, for: host.id, enabled: true)
    }
    await core.runtime.settled()
    #expect(Set(routes.entries) == [.direct, .privateName])
    #expect(!registry.entries.contains { $0.id == "pinned" })
    #expect(core.runtime.service(ServiceLabellers.self, realm: host.realm)?.entries.count == 1)
  } catch {
    await core.runtime.shutdown()
    throw error
  }
  await core.runtime.shutdown()
}

#if os(macOS)
  import CompositionFixtures
  @testable import MobileUI

  @Test @MainActor func leavingServiceAndBackgroundingReleaseTheGrant() async throws {
    QuietWindow.prepareTestProcess()
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let port = try loopbackPort()
    let demo = try DemoHost(notebookPort: port)
    let core = try MobileComposition(directory: root, cache: root.appending(path: "cache")) {
      _, _, _ in demo
    }
    let profile = try await demo.install(in: core)
    core.runtime.service(Demand.self)?.show(profile.id, in: UUID())
    await core.runtime.settled()
    let pages = ServicePages()
    do {
      for background in [false, true] {
        let address = ServiceAddress(port: try loopbackPort())
        let page = pages.page(address)
        await page.start(
          core: core, profile: profile, address: address, generation: 1,
          routes: [.privateName, .localhost], requested: .localhost, remembered: true,
          saveTitle: { _ in })
        let web = try #require(page.web)
        let present = web.customUserAgent?.contains("RelayBar/") == true
        #expect(present)
        let prefs = try #require(core.runtime.service(Profiles.self))
        try prefs.update { $0.open(address, host: profile.id) }
        let persisted = try Data(contentsOf: root.appending(path: "preferences.json"))
        let token = web.customUserAgent?.components(separatedBy: "RelayBar/").last ?? ""
        let absent = !token.isEmpty && persisted.range(of: Data(token.utf8)) == nil
        #expect(absent)
        if background { pages.suspend() } else { page.hide() }
        await page.teardown?.value
        #expect(core.routes.registry.servedPorts(for: profile.id).isEmpty)
        let cleared = web.customUserAgent?.contains("RelayBar/") != true
        #expect(cleared)
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        let clean = !cookies.contains { $0.value == token }
        #expect(clean)
      }
    } catch {
      pages.suspend()
      await core.runtime.shutdown()
      throw error
    }
    await core.runtime.shutdown()
    try await removeTestStore(profile.id)
  }
#endif

#if os(macOS)
  @Test @MainActor func externalRedirectNeedsANewApproval() async throws {
    QuietWindow.prepareTestProcess()
    let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let demo = try DemoHost()
    let core = try MobileComposition(
      directory: root, cache: root.appending(path: "cache"), keys: DemoKeys()
    ) { _, _, _ in demo }
    let host = try await demo.install(in: core)
    let prefs = try #require(core.runtime.service(Profiles.self))
    try prefs.update { $0.set(networkPlugin, for: host.id, enabled: true) }
    core.runtime.service(Demand.self)?.show(host.id, in: UUID())
    await core.runtime.settled()
    let page = ServiceBrowser()
    func wait(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(6)
      while !condition() {
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(25))
      }
    }
    func load(_ address: ServiceAddress) async {
      await page.start(
        core: core, profile: host, address: address, generation: 1,
        routes: [.privateName, .network], requested: nil, remembered: nil, saveTitle: { _ in })
    }
    do {
      let source = try #require(
        ServiceAddress.external("http://dashboard:6006/network-redirect", profile: host))
      let target = try #require(ServiceAddress.external("http://metrics:6006/", profile: host))
      var redirect: ServiceAddress?
      page.redirect = { redirect = $0 }
      await load(source)
      try await wait { page.review.prompt == .destination(.init(name: "dashboard", port: 6006)) }
      page.review.answer(.once)
      try await wait { redirect == target }
      page.stop()
      await load(target)
      try await wait { page.review.prompt == .destination(.init(name: "metrics", port: 6006)) }
      page.review.answer(.always)
      try await wait { page.web?.title == "Run monitor" }
      #expect(prefs.value.destinations?[host.id] == [.init(name: "metrics", port: 6006)])
    } catch {
      page.stop()
      await core.runtime.shutdown()
      throw error
    }
    page.stop()
    await core.runtime.shutdown()
  }
#endif

@Test func publicInternetPreviewRules() throws {
  let json = try LoopbackRules.rules([], blockPrivateNames: true, profileHost: "selected.example")
  let rules = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: String]]])
  func blocked(_ host: String) -> Bool {
    rules.contains { rule in
      ("https://user@" + host + ":8443/asset").range(of: rule["trigger"]!["url-filter"]!,
        options: [.regularExpression, .caseInsensitive]) != nil
    }
  }
  for host in ["localhost", "127.0.0.9", "10.2.3.4", "172.16.0.1", "172.31.255.255", "192.168.0.1",
    "100.64.1.1", "100.127.255.255", "169.254.1.2", "[::1]", "[::ffff:7f00:1]", "[fd00::1]",
    "[fcff::1]", "[fe80::1]", "[febf::1]", "[fec0::1]", "[feff::]", "[64:ff9b::]",
    "[64:ff9b::ffff:ffff]", "a.home.", "example.corp", "printer.", "desk.local", "a.internal.", "a.lan",
    "selected.example.", "home.arpa", "a.home.arpa.", "name.localhost", "a.b.ts.net"] {
    #expect(blocked(host))
  }
  for host in ["images.example.test", "172.32.0.1", "100.128.0.1", "100.63.0.1", "[2606:4700::1]", "[64:ff9b::1:0:0]", "[ff00::1]", "corp.example"] {
    #expect(!blocked(host))
  }
}
