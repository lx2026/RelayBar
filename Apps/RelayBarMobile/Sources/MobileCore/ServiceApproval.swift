import Composition
import CryptoKit
import Darwin
import Foundation
import Network
import RelayWebRoutes
import Security
import WebKit

package let networkPlugin = PluginDescriptor(
  id: "host-network", title: "The Host’s Network",
  summary: "Open other machines the host can reach.", symbol: "network", isOnByDefault: false,
  realmRelativeFeatures: ["routes.network"])

package struct Destination: Codable, Hashable, Sendable {
  package let name: String
  package let port: UInt16
  package var label: String { name + ":" + String(port) }
  package init(name: String, port: UInt16) {
    self.name = name.lowercased()
    self.port = port
  }
}
package struct CertificateInfo: Codable, Equatable, Sendable {
  package let subject: String
  package let fingerprint: String
  package init(subject: String, fingerprint: String) {
    self.subject = subject
    self.fingerprint = fingerprint
  }
  init(_ certificate: SecCertificate) {
    subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unnamed certificate"
    fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
      .map { String(format: "%02X", $0) }.joined(separator: ":")
  }
}
package enum CertificateDecision { case ask, accept, changed }
extension Preferences {
  package func certificateDecision(_ leaf: CertificateInfo, host: UUID, endpoint: Destination)
    -> CertificateDecision
  {
    guard let saved = certificates?[host]?[endpoint] else { return .ask }
    return saved.fingerprint == leaf.fingerprint ? .accept : .changed
  }
  package mutating func pin(_ leaf: CertificateInfo?, host: UUID, endpoint: Destination) {
    if certificates == nil { certificates = [:] }
    certificates?[host, default: [:]][endpoint] = leaf
  }
  package mutating func remember(_ destination: Destination, host: UUID) {
    if destinations == nil { destinations = [:] }
    destinations?[host, default: []].insert(destination)
  }
}

extension ServiceAddress {
  package static func external(_ input: String, profile: Profile) -> Self? {
    let url = input.contains("://") ? input : "http://" + input
    guard let parts = URLComponents(string: url), let name = parts.host?.lowercased(),
      name != profile.host.lowercased(), !name.hasSuffix(".localhost"),
      let scheme = parts.scheme?.lowercased(), eligible(name: name, scheme: scheme),
      parts.user == nil, parts.password == nil, !parts.path.hasPrefix("//"),
      let port = UInt16(exactly: parts.port ?? (scheme == "https" ? 443 : 80)), port > 0
    else { return nil }
    var path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
    if let query = parts.percentEncodedQuery { path += "?" + query }
    if let fragment = parts.percentEncodedFragment { path += "#" + fragment }
    return .init(port: port, path: path, scheme: scheme, destination: name)
  }

  private static func eligible(name: String, scheme: String) -> Bool {
    guard scheme == "http" || scheme == "https", !name.isEmpty, name.utf8.count <= 253,
      !["localhost", "localhost4", "localhost6", "ip6-localhost", "ip6-loopback"].contains(name)
    else { return false }
    var ipv4 = in_addr()
    if inet_aton(name, &ipv4) == 1 {
      let address = UInt32(bigEndian: ipv4.s_addr)
      return scheme == "https" && IPv4Address(name) != nil && address != 0 && address >> 24 != 127
    }
    if name.hasPrefix("["), name.hasSuffix("]") {
      let literal = String(name.dropFirst().dropLast())
      guard scheme == "https", let address = IPv6Address(literal) else { return false }
      let bytes = address.rawValue
      return !bytes.prefix(12).allSatisfy { $0 == 0 }
        && !(bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255)
    }
    guard scheme == "https" || !name.contains(".") else { return false }
    return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
        && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
  }

}

package enum NetworkAccess: ServiceKey { package typealias Value = HostNetwork }
struct NetworkFeature: Feature {
  let profile: Profile
  @Need(WebRoutes.self) var routes
  @Need(WebUpstream.self) var upstream
  @Need(Locations.self) var locations
  @Need(Profiles.self) var preferences
  @Offer(NetworkAccess.self) var access
  func run(_ context: FeatureContext) async throws {
    try routes.register(.network, in: context)
    let prefs = preferences
    try locations.register(
      .init(id: "remote-address") { text in
        guard text.contains("://") || text.contains(":"),
          let address = ServiceAddress.external(text, profile: profile),
          !prefs.value.hosts.contains(where: { $0.host.lowercased() == address.destination })
        else { return nil }
        return .service(address)
      }, in: context)
    let service = HostNetwork(profile: profile, opener: upstream)
    access.set(service)
    try context.effect("External service proxies", cancel: { service.active = false }) {
      await service.stop()
    }
  }
}

@MainActor package final class HostNetwork {
  fileprivate var active = true
  let profile: Profile
  let opener: any RouteStreamOpener
  private var proxies: [UUID: SOCKSProxy] = [:]
  init(profile: Profile, opener: any RouteStreamOpener) {
    self.profile = profile
    self.opener = opener
  }

  package func open(_ address: ServiceAddress, approval: @escaping ProxyApprovalHook) async throws
    -> (UUID, WKWebView)
  {
    guard active, let name = address.destination, let url = address.url(host: name),
      ServiceAddress.external(url.absoluteString, profile: profile) == address
    else { throw URLError(.unsupportedURL) }
    let proxyName = name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let destination = ProxyDestination(host: proxyName, port: address.port)
    let proxy = try await SOCKSProxy.start(privateName: profile.privateName, opener: opener) {
      request in
      guard request == destination else { return .refuse }
      return await approval(request)
    }
    do {
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      var socks = ProxyConfiguration(
        socksv5Proxy: .hostPort(host: "127.0.0.1", port: .init(rawValue: proxy.port)!))
      socks.applyCredential(username: proxy.username, password: proxy.password)
      socks.allowFailover = false
      config.websiteDataStore.proxyConfigurations = [socks]
      // Restrict both scheme and authority before WebKit attempts a connection.
      let escaped = NSRegularExpression.escapedPattern(for: name)
      let tls = address.scheme == "https"
      let port = Int(address.port) == (tls ? 443 : 80) ? "(:\(address.port))?" : ":\(address.port)"
      var rules = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
      for scheme in tls ? ["https", "wss"] : ["http", "ws"] {
        rules.append([
          "trigger": ["url-filter": "^" + scheme + "://" + escaped + port + "/"],
          "action": ["type": "ignore-previous-rules"],
        ])
      }
      let source = String(
        decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
      let list = try await WKContentRuleListStore.default()!.compileContentRuleList(
        forIdentifier: "service-" + address.scheme + "-" + name + "-" + String(address.port),
        encodedContentRuleList: source)
      guard let list, active, !Task.isCancelled else { throw CancellationError() }
      config.userContentController.add(list)
      let id = UUID()
      proxies[id] = proxy
      return (id, WKWebView(frame: .zero, configuration: config))
    } catch {
      await proxy.stop()
      throw error
    }
  }
  package func close(_ id: UUID) async { await proxies.removeValue(forKey: id)?.stop() }
  fileprivate func stop() async {
    for id in Array(proxies.keys) { await close(id) }
  }
}

@MainActor package struct PrivateServiceTrust {
  package let profile: Profile
  package let endpoint: Destination
  package let preferences: PreferenceStore<Preferences>
  package init(profile: Profile, port: UInt16, preferences: PreferenceStore<Preferences>) {
    self.profile = profile
    endpoint = .init(name: profile.privateName, port: port)
    self.preferences = preferences
  }
  package func answer(
    _ challenge: URLAuthenticationChallenge,
    review: (CertificateInfo, CertificateInfo?) async -> Bool
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    let space = challenge.protectionSpace
    guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      space.host.lowercased() == endpoint.name, space.port == Int(endpoint.port),
      let trust = space.serverTrust,
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let cert = chain.first
    else { return (.performDefaultHandling, nil) }
    let leaf = CertificateInfo(cert)
    switch preferences.value.certificateDecision(leaf, host: profile.id, endpoint: endpoint) {
    case .accept: break
    case .changed:
      _ = await review(leaf, preferences.value.certificates?[profile.id]?[endpoint])
      return (.cancelAuthenticationChallenge, nil)
    case .ask:
      if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
      guard await review(leaf, nil) else { return (.cancelAuthenticationChallenge, nil) }
      do {
        try preferences.update { value in
          guard value.certificateDecision(leaf, host: profile.id, endpoint: endpoint) != .changed
          else {
            throw CompositionError("Certificate changed during approval.")
          }
          value.pin(leaf, host: profile.id, endpoint: endpoint)
        }
      } catch { return (.cancelAuthenticationChallenge, nil) }
    }
    return (.useCredential, URLCredential(trust: trust))
  }
}
