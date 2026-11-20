import Composition
import Foundation
import Testing

@testable import MobileCore

@Test func choicesPersistOnlyCatalogKeysAndPreserveOtherOverrides() throws {
  var prefs = Preferences()
  let host = UUID()
  let ids = Set(MobileComposition.plugins.map(\.id))
  #expect(ids.count == 14)
  #expect(
    MobileComposition.plugins.filter { !$0.isOnByDefault }.map(\.id).sorted()
      == [deletePlugin.id, networkPlugin.id, logPlugin.id, labelsPlugin.id].sorted())
  for plugin in MobileComposition.plugins {
    prefs.plugins.set(plugin, enabled: !plugin.isOnByDefault)
    prefs.set(plugin, for: host, enabled: plugin.isOnByDefault)
  }
  let copy = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
  let features = Set(MobileComposition.plugins.flatMap { $0.features + $0.realmRelativeFeatures })
  #expect(Set(copy.plugins.overrides.keys) == ids)
  #expect(Set(copy.hostPlugins![host]!.overrides.keys) == ids)
  #expect(ids.isDisjoint(with: features))
  for plugin in MobileComposition.plugins {
    #expect(copy.enabled(plugin, host: host) == plugin.isOnByDefault)
    prefs.set(plugin, for: host, enabled: nil)
    #expect(prefs.enabled(plugin, host: host) != plugin.isOnByDefault)
  }
}

@Test func savedPagesAndApprovalsSurviveRestart() throws {
  var prefs = Preferences()
  let host = Profile(host: "lab.invalid", account: "reader")
  let other = UUID()
  let endpoint = Destination(name: "dashboard", port: 8080)
  let address = try #require(
    ServiceAddress.external("http://dashboard:8080/log?ticket=temporary", profile: host))
  prefs.open(address, host: host.id)
  prefs.remember(endpoint, host: host.id)
  let leaf = CertificateInfo(subject: "Dashboard", fingerprint: "01")
  prefs.pin(leaf, host: host.id, endpoint: endpoint)
  prefs.set(notebookPlugin, for: host.id, enabled: false)
  let copy = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
  #expect(copy.destinations?[host.id] == [endpoint])
  #expect(copy.destinations?[other] == nil)
  #expect(copy.serviceTabs?[host.id]?.first?.destination == endpoint.name)
  #expect(copy.serviceTabs?[host.id]?.first?.path == "/log")
  #expect(copy.missingPlugin(for: address, host: host.id) == networkPlugin)
  #expect(copy.missingPlugin(for: .init(port: 8080), host: host.id) == nil)
  #expect(
    copy.missingPlugin(kind: "document", path: "/saved.ipynb", host: host.id) == notebookPlugin)
  #expect(copy.missingPlugin(kind: "log", path: "/saved.log", host: host.id) == logPlugin)
  #expect(copy.certificateDecision(leaf, host: host.id, endpoint: endpoint) == .accept)
  #expect(
    copy.certificateDecision(
      .init(subject: leaf.subject, fingerprint: "02"), host: host.id, endpoint: endpoint)
      == .changed)
  #expect(copy.certificateDecision(leaf, host: other, endpoint: endpoint) == .ask)
  #expect(
    copy.certificateDecision(leaf, host: host.id, endpoint: .init(name: endpoint.name, port: 443))
      == .ask)
  #expect(
    copy.certificateDecision(
      leaf, host: host.id, endpoint: .init(name: "other", port: endpoint.port)) == .ask)
  #expect(ServiceAddress.external("http://dashboard.example/", profile: host) == nil)
  #expect(ServiceAddress.external("https://dashboard.example/", profile: host) != nil)
  #expect(ServiceAddress.external("https://192.0.2.1/", profile: host) != nil)
  #expect(ServiceAddress.external("http://127.1/", profile: host) == nil)
  #expect(ServiceAddress.external("http://192.0.2.1/", profile: host) == nil)
}

@Test @MainActor func undoCancelsBeforeSubmission() async throws {
  let removal = PendingRemoval()
  var submissions = 0
  removal.schedule(wait: .milliseconds(10)) {
    submissions += 1
  } finish: { _ in
  }
  removal.undo()
  try await Task.sleep(for: .milliseconds(30))
  #expect(submissions == 0)
  await withCheckedContinuation { done in
    removal.schedule(wait: .zero) {
      submissions += 1
    } finish: { _ in
      done.resume()
    }
  }
  #expect(submissions == 1)
}

@Test func followKeepsSplitUTF8AndResetsOnReplacement() {
  var cursor = LogCursor()
  let line = Data("Epoch 1\n✓".utf8)
  cursor.append(line.dropLast(), reset: false)
  cursor.append(line.suffix(1) + Data("\nEpoch 2".utf8), reset: false)
  #expect(cursor.text == "Epoch 1\n✓\nEpoch 2")
  cursor.append(Data(), reset: true)
  cursor.append(Data("New run".utf8), reset: false)
  #expect(cursor.text == "New run")
}

@Test func hostCacheUsageIncludesUnmigratedFiles() async throws {
  let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let host = UUID()
  let legacy = root.appending(path: host.uuidString)
  try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
  try Data(repeating: 1, count: 23).write(to: legacy.appending(path: "saved"))
  let cache = DocumentCache(directory: root)
  #expect(await cache.size(host) == 23)
  #expect(await cache.size(UUID()) == 0)
  try await cache.clear(host)
  #expect(await cache.size(host) == 0)
}
