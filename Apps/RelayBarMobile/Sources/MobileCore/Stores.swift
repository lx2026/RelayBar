import PreviewSupport
import Composition
import Foundation
import RelayWebRoutes

package enum LoginMethod: String, Codable, Sendable { case automatic, password, key }

package struct Profile: Codable, Equatable, Hashable, Identifiable, Sendable {
  package var id = UUID()
  package var host: String
  package var account: String
  private var internetResources: Bool?
  package var allowsInternetResources: Bool {
    get { internetResources ?? false }
    set { internetResources = newValue ? true : nil }
  }
  package var method: LoginMethod?
  package var port: UInt16 = 22
  package var realm: String { "host-" + id.uuidString.lowercased() }

  package init(host: String, account: String, port: UInt16 = 22) {
    self.host = host
    self.account = account
    self.port = port
  }
}

package struct ReadingPosition: Equatable, Codable, Sendable {
  package var heading: String?
  package var offset: Double = 0
  package var absoluteOffset: Double = 0
  package init(heading: String? = nil, offset: Double = 0, absoluteOffset: Double = 0) {
    self.heading = heading
    self.offset = offset
    self.absoluteOffset = absoluteOffset
  }
}

package struct Visit: Codable, Equatable, Sendable {
  package var profile: UUID
  package var path: String
  package var title: String
  package var pageKind: String?
  package var plainTable: Bool?
  package var excerpt: String
  package var date: Date
  package var stamp: FileStamp
  package var position: ReadingPosition

  package static func following(_ path: String, profile: UUID, stamp: FileStamp) -> Self {
    .init(
      profile: profile, path: path, title: (path as NSString).lastPathComponent, pageKind: "log",
      excerpt: "Log Follow", date: Date(), stamp: stamp, position: .init())
  }
}

package struct Preferences: Codable, Equatable {
  package var hosts: [Profile] = []
  package var lastHost: UUID?
  package var history: [Visit] = []
  package var homeFolders: [UUID: String]?
  package var pinnedPlaces: [UUID: [Place]]?
  package var currentPlaces: [UUID: String]?
  package var folderOrder: [UUID: FolderOrder]?
  package var favourites: [UUID: [String]]?
  package var serviceTabs: [UUID: [ServiceAddress]]?
  package var pinnedServices: [UUID: [ServiceAddress]]?
  package var serviceTitles: [UUID: [UInt16: String]]?
  package var localhostChoices: [UUID: [UInt16: Bool]]?
  package var prompts: [UUID: [String: String]]?
  package var destinations: [UUID: Set<Destination>]?
  package var certificates: [UUID: [Destination: CertificateInfo]]?
  package var plugins = PluginChoices()
  package var hostPlugins: [UUID: PluginChoices]?
  package func enabled(_ plugin: PluginDescriptor, host: UUID) -> Bool {
    hostPlugins?[host]?.overrides[plugin.id] ?? plugins.isEnabled(plugin)
  }
  package func enabled(_ id: String, host: UUID) -> Bool {
    MobileComposition.plugins.first { $0.id == id }.map { enabled($0, host: host) } ?? false
  }
  package func missingPlugin(kind: String, path: String, host: UUID) -> PluginDescriptor? {
    let plugin: PluginDescriptor
    switch (kind, (path as NSString).pathExtension.lowercased()) {
    case (let kind, let ext) where ["image", "document"].contains(kind) && PreviewFileTypes.additionalImages.contains(ext): plugin = PreviewPlugins.moreImages
    case ("log", _): plugin = logPlugin
    case ("document", "ipynb"): plugin = notebookPlugin
    case ("document", "csv"), ("document", "tsv"):
      if history.first(where: { $0.profile == host && $0.path == path })?.plainTable == true {
        return nil
      }
      plugin = tablePlugin
    default: return nil
    }
    return enabled(plugin, host: host) ? nil : plugin
  }
  package mutating func set(_ plugin: PluginDescriptor, for host: UUID, enabled: Bool?) {
    var choices = hostPlugins ?? [:]
    var overrides = choices[host]?.overrides ?? [:]
    overrides[plugin.id] = enabled
    var hostChoice = PluginChoices()
    for descriptor in MobileComposition.plugins {
      if let value = overrides[descriptor.id] { hostChoice.pin(descriptor, enabled: value) }
    }
    choices[host] = hostChoice.overrides.isEmpty ? nil : hostChoice
    hostPlugins = choices
  }
  package func missingPlugin(for address: ServiceAddress, host: UUID) -> PluginDescriptor? {
    address.destination != nil && !enabled(networkPlugin, host: host) ? networkPlugin : nil
  }
  package mutating func open(_ address: ServiceAddress, host: UUID) {
    var tabs = serviceTabs ?? [:]
    if !tabs[host, default: []].contains(address.saved) {
      tabs[host, default: []].append(address.saved)
    }
    serviceTabs = tabs
  }

  package mutating func record(_ visit: Visit) {
    history.removeAll { $0.profile == visit.profile && $0.path == visit.path }
    history.insert(visit, at: 0)
    history = Array(history.prefix(100))
  }
}

package struct Identity: Codable, Equatable, Sendable {
  package let algorithm: String
  package let fingerprint: String
}

package struct FileStamp: Codable, Equatable, Sendable {
  package var size: UInt64?
  package var modified: UInt32?
  package var directory: Bool
}

package struct FileRow: Identifiable, Sendable {
  package var remove: (@Sendable () async throws -> Void)?
  package var symbolicLink = false
  package var companions: [String] = []
  package var id: String { name }
  package let name: String
  package let stamp: FileStamp
  package init(name: String, stamp: FileStamp) {
    self.name = name
    self.stamp = stamp
  }
}

package struct FolderListing: Sendable {
  package let rows: [FileRow]
  package let truncated: Bool
  package var notice: String { truncated ? "Showing the first 10,000 items" : "" }
}

extension RemoteFiles {
  package func listing(_ path: String) async throws -> FolderListing {
    try await .init(rows: list(path), truncated: false)
  }
}

package protocol RemoteFiles: Sendable {
  func home() async throws -> String
  func resolve(_ path: String) async throws -> String
  func stat(_ path: String) async throws -> FileStamp
  func listing(_ path: String) async throws -> FolderListing
  func list(_ path: String) async throws -> [FileRow]
  func read(_ path: String, limit: Int) async throws -> Data
}

package enum ConnectionEvent: Sendable {
  case connecting
  case ready
  case lost
  case failed(String, passwordRefused: Bool = false)
}

package protocol HostConnection: Sendable {
  var routeOpener: (any RouteStreamOpener)? { get }
  func files() async throws -> any RemoteFiles
  func run(_ publish: @escaping @MainActor @Sendable (ConnectionEvent) -> Void) async
  func networkPathChanged() async
  func suspend() async
}

package enum HostState: Equatable, Sendable {
  case idle, connecting, connected
  case failed(String)
  package var label: String {
    switch self {
    case .idle: "Not connected"
    case .connecting: "Reconnecting…"
    case .connected: "Connected"
    case .failed(let reason): reason
    }
  }
}

@MainActor package final class HostStates: ObservableObject {
  @Published package var values: [UUID: HostState] = [:]
}

package struct HostEndpoint {
  package let host: String
  package let account: String?
  package let port: UInt16
  package init(_ profile: Profile) {
    host = profile.host
    account = profile.account
    port = profile.port
  }
  package init(_ input: String) throws {
    let invalid = CompositionError("Enter a host, user@host:port or ssh -p PORT user@host.")
    var parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
    if parts.first == "ssh" { parts.removeFirst() }
    var portText: String?
    if parts.first == "-p", parts.count == 3 {
      portText = parts[1]
      parts.removeFirst(2)
    }
    guard parts.count == 1 else { throw invalid }
    let address = parts[0].components(separatedBy: "@")
    guard address.count <= 2, address.allSatisfy({ !$0.isEmpty }) else { throw invalid }
    account = address.count == 2 ? address[0] : nil
    let pair = address[address.count - 1].components(separatedBy: ":")
    guard pair.count <= 2, !pair[0].isEmpty, !pair[0].hasPrefix("-"), !pair[0].contains("/"),
      pair.count == 1 || portText == nil
    else { throw invalid }
    host = pair[0]
    guard let number = UInt16(pair.count == 2 ? pair[1] : portText ?? "22"), number > 0 else {
      throw invalid
    }
    port = number
  }
}

extension HostConnection {
  package var routeOpener: (any RouteStreamOpener)? { nil }
  package func networkPathChanged() async {}
}
