import Foundation

package struct Place: Codable, Equatable, Identifiable, Sendable {
  package let path: String
  // Old favourites stored only the path. Resolve their type on connection.
  package var directory: Bool?
  package var id: String { path }
  package init(path: String, directory: Bool?) {
    self.path = path
    self.directory = directory
  }
}

package enum FolderOrder: String, Codable, CaseIterable {
  case modified = "Modified"
  case name = "Name"
}

extension Preferences {
  package mutating func migratePlaces() {
    for (host, paths) in favourites ?? [:] {
      var places = pinnedPlaces?[host] ?? []
      for path in paths where !places.contains(where: { $0.path == path }) {
        places.append(.init(path: path, directory: nil))
      }
      if pinnedPlaces == nil { pinnedPlaces = [:] }
      pinnedPlaces?[host] = places
    }
    favourites = nil
  }

  package func places(for host: UUID) -> [Place] {
    guard enabled("favorites", host: host) else { return [] }
    return (pinnedPlaces?[host] ?? []).filter { $0.path != homeFolders?[host] }
  }

  package mutating func togglePin(_ place: Place, host: UUID) {
    if pinnedPlaces == nil { pinnedPlaces = [:] }
    if pinnedPlaces?[host]?.contains(where: { $0.path == place.path }) == true {
      pinnedPlaces?[host]?.removeAll { $0.path == place.path }
      if currentPlaces?[host] == place.path { currentPlaces?[host] = nil }
    } else if place.path != homeFolders?[host] {
      pinnedPlaces?[host, default: []].append(place)
    }
  }

  package mutating func select(_ place: Place?, host: UUID) {
    if currentPlaces == nil { currentPlaces = [:] }
    currentPlaces?[host] = place?.path
  }
}

package struct PathMatch: Identifiable, Sendable {
  package let place: Place
  package let input: String
  package var id: String { place.path }
}

package typealias CompletionSource =
  @Sendable (String, String?, any RemoteFiles) async throws -> [PathMatch]

package enum LocationResultSource: Sendable {
  case paths(CompletionSource)
  case files(NameIndex)

  package static func sources(search: NameIndex?) -> [Self] {
    [.paths(completePath)] + (search.map { [.files($0)] } ?? [])
  }
}

package let completePath: CompletionSource = { query, base, files in
  guard !query.isEmpty, !query.contains("://") else { return [] }
  let start = query.lastIndex(of: "/").map { query.index(after: $0) } ?? query.startIndex
  let prefix = String(query[..<start])
  guard !prefix.isEmpty || (!query.contains(":") && !query.contains("@") && UInt16(query) == nil)
  else { return [] }
  let fragment = query[start...].lowercased()
  let parent: String
  if prefix.hasPrefix("~/") {
    parent = (try await files.home() as NSString).appendingPathComponent(
      String(prefix.dropFirst(2)))
  } else if prefix.hasPrefix("/") {
    parent = prefix
  } else if let base {
    parent = (base as NSString).appendingPathComponent(prefix)
  } else {
    return []
  }
  let folder = parent.count > 1 && parent.hasSuffix("/") ? String(parent.dropLast()) : parent
  return try await files.list(folder).filter {
    $0.name.lowercased().hasPrefix(fragment)
  }
  .sorted { a, b in
    a.stamp.directory != b.stamp.directory
      ? a.stamp.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending
  }.map { row in
    PathMatch(
      place: Place(
        path: (folder as NSString).appendingPathComponent(row.name),
        directory: row.stamp.directory),
      input: prefix + row.name + (row.stamp.directory ? "/" : ""))
  }
}
