import Composition
import Foundation
import RelayTransport

package let logPlugin = PluginDescriptor(
  id: "log-follow", title: "Log Follow",
  summary: "Follow a growing text file.", symbol: "text.alignleft", isOnByDefault: false,
  realmRelativeFeatures: ["pages.follow"])
package let deletePlugin = PluginDescriptor(
  id: "delete-undo", title: "Delete with Undo",
  summary: "Delete a file with five seconds to undo.", symbol: "trash", isOnByDefault: false,
  realmRelativeFeatures: ["actions.remove"])

package func canFollow(_ path: String) -> Bool {
  let ext = (path as NSString).pathExtension.lowercased()
  return Format.text.descriptor.extensions.contains(ext)
    || ["out", "err", "text", "md", "json", "csv", "tsv"].contains(ext)
}
package enum FileCommand { case ordinary, deleteFile, follow }
struct DeleteFeature: Feature {
  @Need(FileActions.self) var actions
  @Need(Files.self) var files
  func run(_ context: FeatureContext) async throws {
    try actions.register(
      .init(id: "delete", title: "Delete…", command: .deleteFile) { _, _ in
        try context.checkActive()
      }, in: context)
  }
}
struct LogFeature: Feature {
  @Need(FileActions.self) var actions
  @Need(Pages.self) var pages
  func run(_ context: FeatureContext) async throws {
    try pages.register(.init(id: "log") { view, path in view.log(path) }, in: context)
    try actions.register(
      .init(id: "follow", title: "Follow log", command: .follow) { _, _ in
        try context.checkActive()
      }, in: context)
  }
}

@MainActor package final class PendingRemoval: ObservableObject {
  package init() {}
  @Published package private(set) var submitted = false
  private var timer: Task<Void, Never>?
  package func schedule(
    wait: Duration = .seconds(5), remove: @escaping @MainActor () async throws -> Void,
    finish: @escaping @MainActor (String?) -> Void
  ) {
    guard timer == nil else { return }
    submitted = false
    timer = Task {
      do { try await Task.sleep(for: wait) } catch { return }
      // Undo can run after the sleep has finished but before this task resumes.
      guard !Task.isCancelled else { return }
      submitted = true
      do {
        try await remove()
        finish(nil)
      } catch { finish(error.localizedDescription) }
      timer = nil
    }
  }
  package func undo() {
    guard !submitted else { return }
    timer?.cancel()
    timer = nil
  }
}

package struct LogCursor: Sendable {
  package init() {}
  private var identity: SFTPTailIdentity?
  private var offset: UInt64?
  private var bytes = Data()
  package var text: String { String(decoding: bytes, as: UTF8.self) }
  mutating func append(_ addition: Data, reset: Bool) {
    if reset { bytes.removeAll() }
    bytes.append(addition)
    if bytes.count > 65536 { bytes = Data(bytes.suffix(65536)) }
  }
  package mutating func poll(_ path: String, files: any RemoteFiles) async throws {
    if let adapter = (files as? RemoteAdapter) ?? (files as? IndexedFiles<RemoteAdapter>)?.base {
      let client = try await adapter.session.sftp()
      let start: UInt64
      if let offset {
        start = offset
      } else {
        let size = try await files.stat(path).size ?? 0
        start = size - min(size, 65536)
      }
      let result = try await client.tail(path, offset: start, identity: identity)
      try Task.checkCancellation()
      append(result.bytes, reset: result.reset)
      offset = result.reset ? nil : result.nextOffset
      identity = result.reset ? nil : result.identity
    } else {
      let snapshot = try await files.read(path, limit: 2 << 20)
      try Task.checkCancellation()
      append(snapshot, reset: true)
    }
  }
}
