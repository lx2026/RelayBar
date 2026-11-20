import PreviewSupport
import Composition
import Foundation
import RelayWebRoutes

package let localhostPlugin = PluginDescriptor(
  id: "localhost", title: "Localhost Compatibility",
  summary: "Open trusted websites that require localhost.", symbol: "arrow.triangle.2.circlepath",
  isOnByDefault: true,
  realmRelativeFeatures: ["exact-localhost"])
package let pinsPlugin = PluginDescriptor(
  id: "pinned-services", title: "Pinned Websites",
  summary: "Keep websites on Home and in Open Location.", symbol: "pin", isOnByDefault: true,
  realmRelativeFeatures: ["services.pins"])
package let labelsPlugin = PluginDescriptor(
  id: "service-labels", title: PreviewPlugins.websiteTitle,
  summary: PreviewPlugins.websiteSummary, symbol: "tag", isOnByDefault: false,
  realmRelativeFeatures: ["services.titles"])

package struct ServiceAddress: Codable, Hashable, Sendable {
  package var destination: String?
  package let port: UInt16
  package var path = "/"
  package var scheme = "http"
  package init(
    port: UInt16, path: String = "/", scheme: String = "http", destination: String? = nil
  ) {
    self.destination = destination
    self.port = port
    self.path = path
    self.scheme = scheme
  }
  package var saved: Self {
    Self(
      port: port, path: String(path.prefix { $0 != "?" && $0 != "#" }), scheme: scheme,
      destination: destination)
  }
  package func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encodeIfPresent(destination, forKey: .destination)
    try fields.encode(port, forKey: .port)
    try fields.encode(saved.path, forKey: .path)
    try fields.encode(scheme, forKey: .scheme)
  }
  package func url(host: String) -> URL? {
    var parts = URLComponents()
    parts.scheme = scheme
    parts.host = destination ?? host
    parts.port = Int(port)
    guard let base = parts.url, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
    return URL(string: base.absoluteString + path)
  }
  package static func parse(_ text: String, profile: Profile, kind: String) -> Self? {
    switch kind {
    case "port":
      let digits = text.hasPrefix(":") ? String(text.dropFirst()) : text
      guard digits.allSatisfy(\.isNumber), let port = UInt16(digits), port > 0 else { return nil }
      return Self(port: port)
    case "host-port", "address":
      let full = kind == "address"
      guard text.contains("://") == full,
        let c = URLComponents(string: full ? text : "http://" + text),
        let host = c.host?.lowercased(),
        [profile.host.lowercased(), "localhost", profile.privateName].contains(host),
        let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
        c.user == nil, c.password == nil,
        full || c.port != nil, let port = UInt16(exactly: c.port ?? (scheme == "https" ? 443 : 80)),
        port > 0, !c.path.hasPrefix("//")
      else { return nil }
      var path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
      if let query = c.percentEncodedQuery { path += "?" + query }
      if let fragment = c.percentEncodedFragment { path += "#" + fragment }
      return Self(port: port, path: path, scheme: scheme)
    default: return nil
    }
  }
}

extension Profile {
  package var privateName: String { id.uuidString.lowercased() + ".localhost" }
}
package enum WebRoute: String, Identifiable, Sendable {
  case direct, privateName, localhost, network
  package var id: Self { self }
}
package enum WebRoutes: ServiceKey { package typealias Value = Registry<WebRoute> }
package enum WebUpstream: ServiceKey { package typealias Value = any RouteStreamOpener }
package enum PinnedServices: ServiceKey { package typealias Value = Bool }

struct RouteFeature: Feature {
  let route: WebRoute
  @Need(WebRoutes.self) var registry
  func run(_ context: FeatureContext) async throws { try registry.register(route, in: context) }
}
struct ServiceResolvers: Feature {
  @Need(Profiles.self) var preferences
  let profile: Profile
  @Need(Locations.self) var locations
  func run(_ context: FeatureContext) async throws {
    let prefs = preferences
    for kind in ["port", "host-port", "address"] {
      try locations.register(
        .init(
          id: kind,
          all: { input in
            let name = URLComponents(string: kind == "address" ? input : "http://" + input)?.host?
              .lowercased()
            if kind == "port" || name == "localhost" {
              return ServiceAddress.parse(input, profile: profile, kind: kind).map {
                [.service($0)]
              } ?? []
            }
            return prefs.value.hosts.compactMap { owner in
              guard let address = ServiceAddress.parse(input, profile: owner, kind: kind) else {
                return nil
              }
              return owner == profile ? .service(address) : .otherService(owner, address)
            }
          }), in: context)
    }
  }
}
struct PinFeature: Feature {
  let profile: Profile
  @Offer(PinnedServices.self) var active
  @Need(Locations.self) var locations
  @Need(Profiles.self) var preferences
  func run(_ context: FeatureContext) async throws {
    active.set(true)
    let prefs = preferences
    try locations.register(
      .init(
        id: "pinned",
        all: { query in
          guard !query.isEmpty else { return [] }
          return (prefs.value.pinnedServices?[profile.id] ?? []).filter {
            prefs.value.serviceTitles?[profile.id]?[$0.port]?.caseInsensitiveCompare(query)
              == .orderedSame
          }.map(Location.service)
        }), in: context)
  }
}
