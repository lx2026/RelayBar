import Composition
import Foundation
import Network
import RelayWebRoutes
import WebKit

/// Serialize listener acquisition and teardown across suspension points (including cookie writes).
@MainActor package final class WebRoutePool {
  package init() {}

  let registry = GateRegistry()
  private var gates: [UInt16: (LocalhostGate, Int)] = [:]
  private struct HostProxy {
    let server: SOCKSProxy
    let store: WKWebsiteDataStore
    var pages: [UUID: ProxyDestination] = [:]
    var cookies: [UUID: HTTPCookie] = [:]
  }
  private var hosts: [UUID: HostProxy] = [:]
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private func enter() async {
    if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
  }
  private func leave() {
    if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
  }

  package func open(profile: Profile, port: UInt16, opener: any RouteStreamOpener) async throws
    -> WebLease
  {
    await enter()
    defer { leave() }
    try Task.checkCancellation()
    if hosts[profile.id] == nil {
      let proxy = try await SOCKSProxy.start(privateName: profile.privateName, opener: opener)
      var config = ProxyConfiguration(
        socksv5Proxy: .hostPort(host: "127.0.0.1", port: .init(rawValue: proxy.port)!))
      config.applyCredential(username: proxy.username, password: proxy.password)
      config.matchDomains = [".localhost"]
      config.allowFailover = false
      let store = WKWebsiteDataStore(forIdentifier: profile.id)
      store.proxyConfigurations = [config]
      hosts[profile.id] = HostProxy(server: proxy, store: store)
    }
    let lease = WebLease(
      profile: profile, port: port, store: hosts[profile.id]!.store, opener: opener)
    hosts[profile.id]!.pages[lease.id] = ProxyDestination(host: profile.privateName, port: port)
    update(profile.id)
    return lease
  }
  private func update(_ profile: UUID) {
    if let host = hosts[profile] { host.server.setDestinations(Set(host.pages.values)) }
  }

  package func authorize(_ lease: WebLease, web: WKWebView) async throws {
    await enter()
    defer { leave() }
    try Task.checkCancellation()
    let port = lease.port
    guard lease.token == nil, hosts[lease.profile.id]?.pages[lease.id] != nil else {
      throw CompositionError("This service page is no longer available.")
    }
    if gates[port] == nil {
      gates[port] = (try await LocalhostGate.start(port: port, registry: registry), 0)
    }
    gates[port]!.1 += 1
    let suffix = port == 80 ? "" : ":\(port)"
    let token = registry.register(
      profile: lease.profile.id, privateName: lease.profile.privateName,
      ports: [port],
      origins: Set(["localhost", "127.0.0.1", "[::1]"].map { "http://" + $0 + suffix }),
      opener: lease.opener)
    lease.token = token
    do {
      // A page only needs its own grant. This subset stays valid if a sibling page closes.
      let allowed = registry.servedPorts(for: lease.profile.id).intersection([port])
      guard allowed.contains(port) else {
        throw CompositionError("The localhost listener stopped.")
      }
      try await LoopbackRules.install(on: web, ports: allowed)
      let ua = try await web.evaluateJavaScript("navigator.userAgent") as? String ?? "Mozilla/5.0"
      let cookies = HTTPCookie.cookies(
        withResponseHeaderFields: [
          "Set-Cookie":
            "\(GateToken.cookieName(for: port))=\(token.value); Path=/; HttpOnly; SameSite=Strict"
        ], for: URL(string: "http://localhost" + suffix + "/")!)
      guard let cookie = cookies.first, cookie.isHTTPOnly, cookie.isSessionOnly else {
        throw CompositionError("Could not create a session cookie.")
      }
      hosts[lease.profile.id]?.cookies[lease.id] = cookie
      lease.cookie = cookie
      await lease.store.httpCookieStore.setCookie(cookie)
      try Task.checkCancellation()
      lease.web = web
      web.customUserAgent = ua + " " + token.userAgentComponent
    } catch {
      await revoke(lease)
      throw error
    }
  }
  private func revoke(_ lease: WebLease) async {
    guard let token = lease.token else { return }
    lease.web?.stopLoading()
    lease.web?.customUserAgent = nil
    lease.web = nil
    lease.token = nil
    await registry.revoke(token)
    if let cookie = lease.cookie {
      hosts[lease.profile.id]?.cookies.removeValue(forKey: lease.id)
      let jar = lease.store.httpCookieStore
      if await jar.allCookies().contains(where: {
        $0.name == cookie.name && $0.value == cookie.value
      }) {
        if let remaining = hosts[lease.profile.id]?.cookies.values.first(where: {
          $0.name == cookie.name
        }) {
          await jar.setCookie(remaining)
        } else {
          await jar.deleteCookie(cookie)
        }
      }
      lease.cookie = nil
    }
    if var gate = gates[lease.port] {
      gate.1 -= 1
      if gate.1 == 0 {
        gates.removeValue(forKey: lease.port)
        await gate.0.stop()
      } else {
        gates[lease.port] = gate
      }
    }
  }
  package func close(_ lease: WebLease) async {
    await enter()
    defer { leave() }
    await revoke(lease)
    hosts[lease.profile.id]?.pages.removeValue(forKey: lease.id)
    update(lease.profile.id)
    if hosts[lease.profile.id]?.pages.isEmpty == true,
      let host = hosts.removeValue(forKey: lease.profile.id)
    {
      await registry.revokeAll(for: lease.profile.id)
      await host.server.stop()
    }
  }
}

@MainActor package final class WebLease {
  let id = UUID()
  let profile: Profile
  let port: UInt16
  let opener: any RouteStreamOpener
  package let store: WKWebsiteDataStore
  fileprivate(set) var token: GateToken?
  fileprivate var cookie: HTTPCookie?
  fileprivate weak var web: WKWebView?
  init(profile: Profile, port: UInt16, store: WKWebsiteDataStore, opener: any RouteStreamOpener) {
    self.profile = profile
    self.port = port
    self.store = store
    self.opener = opener
  }
  package func makeView() -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = store
    return WKWebView(frame: .zero, configuration: config)
  }
}

package enum LoopbackRules {
  // WebKit canonicalizes numeric IP spellings before filtering. Match the entire
  // authority so userinfo, trailing dots and explicit/default ports cannot widen an exception.
  static let literalHosts = [
    #"localhost\.?"#, #"[a-z0-9.-]+\.localhost\."#, #"\[::\]"#, #"127\.[0-9.]+"#, #"0\.0\.0\.0"#,
    #"\[::1\]"#, #"\[::ffff:[0-9a-f:.]+\]"#,
  ]
  static func rules(_ ports: Set<UInt16>, blockPrivateNames: Bool = false, profileHost: String? = nil) throws -> String {
    func rule(_ pattern: String, _ action: String) -> [String: Any] {
      ["trigger": ["url-filter": pattern], "action": ["type": action]]
    }
    var rules = literalHosts.map { rule("^[a-z]+://([^/]*@)?" + $0 + "(:[0-9]+)?/", "block") }
    if blockPrivateNames {
      // WebKit applies these filters to canonical URL authorities, before DNS.
      let hosts = [
        #"[^./:@]+\.?"#, #"0\.[0-9.]+"#, #"10\.[0-9.]+"#, #"192\.168\.[0-9.]+"#,
        #"172\.1[6-9]\.[0-9.]+"#, #"172\.2[0-9]\.[0-9.]+"#, #"172\.3[01]\.[0-9.]+"#,
        #"100\.6[4-9]\.[0-9.]+"#, #"100\.[7-9][0-9]\.[0-9.]+"#,
        #"100\.1[01][0-9]\.[0-9.]+"#, #"100\.12[0-7]\.[0-9.]+"#, #"169\.254\.[0-9.]+"#,
        #"\[f[cd][0-9a-f][0-9a-f]:[^\]]+\]"#, #"\[fe[89a-f][0-9a-f]:[^\]]+\]"#,
        #"\[64:ff9b::([0-9a-f]+:)?[0-9a-f]*\]"#, #"\[::[0-9a-f:.]*\]"#,
      ] + [#"local"#, #"internal"#, #"lan"#, #"home"#, #"corp"#, #"home\.arpa"#, #"localhost"#, #"ts\.net"#].map {
        #"([^/@:]+\.)?"# + $0 + #"\.?"#
      }
      let profile = profileHost?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
      let exact = profile.flatMap { $0.isEmpty ? nil : NSRegularExpression.escapedPattern(for: $0) + #"\.?"# }
      for host in hosts + (exact.map { [$0] } ?? []) {
        rules.append(rule("^[a-z]+://([^/]*@)?" + host + "(:[0-9]+)?/", "block"))
      }
    }
    if blockPrivateNames || !ports.isEmpty {
      rules.append(rule(#"^[a-z]+://([^/]*@)?[a-z0-9.-]+\.localhost(:[0-9]+)?/"#, "block"))
    }
    for port in ports.sorted() {
      for host in ["localhost", #"127\.0\.0\.1"#, #"\[::1\]"#] {
        for scheme in ["http", "ws"] {
          rules.append(
            rule(
              "^" + scheme + "://" + host + (port == 80 ? "(:80)?" : ":\(port)") + "/",
              "ignore-previous-rules"))
        }
      }
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
  }
  @MainActor package static func install(on web: WKWebView, ports: Set<UInt16>) async throws {
    let source = try rules(ports)
    let store = WKContentRuleListStore.default()!
    let name = "relay-loopback-v1-" + ports.sorted().map(String.init).joined(separator: "-")
    let list = try await store.compileContentRuleList(
      forIdentifier: name, encodedContentRuleList: source)
    guard let list else { throw CompositionError("Could not protect loopback ports.") }
    web.configuration.userContentController.add(list)
  }
}

package func directReachable(host: String, port: UInt16) async -> Bool {
  guard let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
  let connection = NWConnection(host: .init(host), port: endpoint, using: .tcp)
  let queue = DispatchQueue(label: "service.direct")
  let (events, result) = AsyncStream<Bool>.makeStream()
  connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
      result.yield(true)
      result.finish()
    case .failed, .cancelled: result.finish()
    default: break
    }
  }
  connection.start(queue: queue)
  queue.asyncAfter(deadline: .now() + 0.65) { result.finish() }
  defer { connection.cancel() }
  for await ready in events { return ready }
  return false
}

package enum ServiceChoice {
  package static func initial(reachable: Bool) -> WebRoute { reachable ? .direct : .privateName }
  package static func offer(
    route: WebRoute, enabled: Bool, remembered: Bool?, status: Int? = nil,
    redirect: String? = nil, detail: String = ""
  ) -> Bool {
    let body = detail.lowercased()
    let refused =
      status == 421
      || ([400, 403].contains(status) && body.contains("host")
        && ["block", "refus", "invalid", "not allowed", "non-local", "disallowed", "untrusted"]
          .contains(where: body.contains))
    return route == .privateName && enabled && remembered != false
      && (refused || redirect?.lowercased() == "localhost")
  }
}

#if os(macOS)
  // The network process can briefly retain a disposed fixture view.
  @MainActor package func removeTestStore(_ id: UUID) async throws {
    for attempt in 0..<30 {
      do {
        try await WKWebsiteDataStore.remove(forIdentifier: id)
        return
      } catch {
        if attempt == 29 { throw error }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
  }
#endif
