import Combine
import Composition
import Foundation
import SwiftUI

@MainActor package final class Registry<Entry: Identifiable>: ObservableObject {
  @Published package private(set) var entries: [Entry] = []

  private var inherited: [Entry] = []
  private var local: [Entry] = []
  private var subscription: AnyCancellable?

  init(parent: Registry<Entry>? = nil) {
    subscription = parent?.$entries.sink { [weak self] entries in
      guard let self else { return }
      inherited = entries
      publish()
    }
  }
  private func publish() { entries = local + inherited }
  func register(_ entry: Entry, in context: FeatureContext) throws {
    guard !entries.contains(where: { $0.id == entry.id }) else {
      throw CompositionError("Duplicate registration.")
    }
    try context.effect(
      "Registration",
      cancel: { [weak self] in
        self?.local.removeAll { $0.id == entry.id }
        self?.publish()
      }
    ) {}
    local.append(entry)
    publish()
  }
}

@MainActor package protocol WorkspaceViews {
  func log(_ path: String) -> AnyView
  func home() -> AnyView
  func folder(_ path: String) -> AnyView
  func reader(_ path: String) -> AnyView
  func continueReading() -> AnyView
  func places() -> AnyView
  func recent() -> AnyView
  func openServices() -> AnyView
  func browser(_ url: String) -> AnyView
  func services() -> AnyView
}

package struct PageKind: Identifiable {
  package let id: String
  package let render: @MainActor (any WorkspaceViews, String) -> AnyView
}
package struct HomeSection: Identifiable {
  package let id: String
  package let order: Int
  package let render: @MainActor (any WorkspaceViews) -> AnyView
}
package struct FileAction: Identifiable {
  package let id: String
  package let title: String
  package var command: FileCommand = .ordinary
  package let perform: @MainActor (String, () -> Void) throws -> Void
}
package struct LocationResolver: Identifiable {
  package let id: String
  package let matches: @MainActor (String) -> [Location]
  init(id: String, _ resolve: @escaping @MainActor (String) -> Location?) {
    self.id = id
    self.matches = { resolve($0).map { [$0] } ?? [] }
  }
  init(id: String, all: @escaping @MainActor (String) -> [Location]) {
    self.id = id
    self.matches = all
  }
  @MainActor package func resolve(_ text: String) -> Location? { matches(text).first }
  @MainActor package static func candidates(_ text: String, resolvers: [Self], hosts: [Profile])
    -> [Location]
  {
    var results: [Location] = []
    for target in resolvers.flatMap({ $0.matches(text) }) {
      var options = [target]
      if case .host(let name) = target {
        let known = hosts.filter { $0.host == name || $0.account + "@" + $0.host == name }
        if !known.isEmpty { options = known.map(Location.profile) }
      }
      for option in options where !results.contains(option) { results.append(option) }
    }
    return results
  }
}
struct DocumentObserver: Identifiable {
  let id: String
  let record: @MainActor (ReadDocument, inout Preferences) -> Void
}
enum DocumentObservers: ServiceKey { typealias Value = Registry<DocumentObserver> }
package enum ThumbnailLimit: ServiceKey { package typealias Value = Int }

struct BuiltInEntries: Feature {
  @Need(Pages.self) var pages
  @Need(Sections.self) var sections
  @Need(FileActions.self) var actions
  @Need(Locations.self) var locations
  func run(_ context: FeatureContext) async throws {
    try pages.register(.init(id: "home") { view, _ in view.home() }, in: context)
    try pages.register(.init(id: "folder") { view, path in view.folder(path) }, in: context)
    try pages.register(.init(id: "tabs") { view, _ in view.openServices() }, in: context)
    try pages.register(.init(id: "service") { view, url in view.browser(url) }, in: context)
    for kind in ["document", "image"] {
      try pages.register(.init(id: kind) { view, path in view.reader(path) }, in: context)
    }
    try sections.register(.init(id: "continue", order: 0) { $0.continueReading() }, in: context)
    try sections.register(.init(id: "places", order: 1) { $0.places() }, in: context)
    try sections.register(.init(id: "recent", order: 3) { $0.recent() }, in: context)
    try sections.register(.init(id: "services", order: 4) { $0.services() }, in: context)
    try actions.register(.init(id: "open", title: "Open") { _, open in open() }, in: context)
    try locations.register(
      .init(id: "host") { input in
        guard !input.isEmpty, UInt16(input) == nil, !input.contains("/"),
          !input.contains(":") || input.contains("@"),
          input.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        return .host(input)
      }, in: context)
  }
}

struct FavouritesFeature: Feature {
  let host: UUID
  @Need(FileActions.self) var actions
  @Need(Profiles.self) var preferences
  func run(_ context: FeatureContext) async throws {
    let preferences = preferences
    try actions.register(
      .init(id: "favourite", title: "Pin") { path, _ in
        try preferences.update { $0.togglePin(.init(path: path, directory: false), host: host) }
      }, in: context)
  }
}

struct PromptSearchFeature: Feature {
  let host: UUID
  @Need(Profiles.self) var preferences
  @Need(Locations.self) var locations
  @Need(DocumentObservers.self) var observers
  func run(_ context: FeatureContext) async throws {
    try observers.register(
      .init(id: "image-prompt") { doc, preferences in
        guard doc.isImage else { return }
        var prompts = preferences.prompts ?? [:]
        prompts[host, default: [:]][doc.path] = doc.imagePrompt.map { String($0.prefix(4096)) }
        preferences.prompts = prompts
      }, in: context)
    let preferences = preferences
    try locations.register(
      .init(
        id: "prompt",
        all: { input in
          guard input.hasPrefix("prompt:"), let entries = preferences.value.prompts?[host] else {
            return []
          }
          let query = input.dropFirst(7).trimmingCharacters(in: .whitespaces)
          guard !query.isEmpty else { return [] }
          return entries.keys.sorted().filter {
            entries[$0]?.localizedCaseInsensitiveContains(query) == true
          }.map(Location.path)
        }), in: context)
  }
}

struct PathResolverFeature: Feature {
  @Need(Locations.self) var locations
  @Need(Formats.self) var formats
  func run(_ context: FeatureContext) async throws {
    let formats = formats
    try locations.register(
      .init(id: "path") { input in
        guard !input.contains("://") else { return nil }
        return input.hasPrefix("~") || input.contains("/") || formats.descriptor(for: input) != nil
          ? .path(input) : nil
      }, in: context)
  }
}
