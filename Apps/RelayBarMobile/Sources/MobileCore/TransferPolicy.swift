import Combine
import Composition
import Foundation
import Network

/// One monitor per runtime. File operations consult it between bounded reads.
@MainActor package final class TransferPolicy: ObservableObject {
  private let monitor = NWPathMonitor()
  let changes = PassthroughSubject<Void, Never>()
  private var previous: NWPath?
  @Published package private(set) var costly = false
  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let costly = Self.restrict(
        enabled: true, expensive: path.isExpensive, constrained: path.isConstrained)
      Task { @MainActor in
        guard let self else { return }
        self.costly = costly
        let old = self.previous
        self.previous = path
        if let old, old != path { self.changes.send() }
      }
    }
    monitor.start(queue: DispatchQueue(label: "reader.path"))
  }
  deinit { monitor.cancel() }
  nonisolated static func restrict(enabled: Bool, expensive: Bool, constrained: Bool) -> Bool {
    enabled && (expensive || constrained)
  }
}

package protocol RangeFiles: RemoteFiles {
  func bytes(_ path: String, range: Range<UInt64>, interactive: Bool) async throws -> Data
}

package struct MediaSource: Sendable {
  package let path: String
  package let size: Int64
  let files: any RangeFiles
  package init(path: String, stamp: FileStamp, files: any RemoteFiles) throws {
    guard let ranged = files as? any RangeFiles, let length = stamp.size,
      let size = Int64(exactly: length), size > 0
    else { throw CompositionError("Media size unavailable.") }
    self.path = path
    self.size = size
    self.files = ranged
  }
  package func read(offset: Int64, length: Int, interactive: Bool) async throws -> Data {
    try Task.checkCancellation()
    guard offset >= 0, offset <= size, length >= 0 else { throw URLError(.badURL) }
    let count = min(size - offset, Int64(length))
    let bytes = try await files.bytes(
      path, range: UInt64(offset)..<UInt64(offset + count), interactive: interactive)
    try Task.checkCancellation()
    guard bytes.count == count else { throw CompositionError("The video changed during playback.") }
    return bytes
  }
}

struct ThumbnailPolicyFeature: Feature {
  @Constant var policy: TransferPolicy
  @Offer(ThumbnailLimit.self) var limit
  func run(_ context: FeatureContext) async throws {
    let subscription = policy.$costly.removeDuplicates().sink { costly in
      limit.set(costly ? 0 : DocumentCache.thumbnailSourceLimit)
    }
    try context.effect("Thumbnail path monitor", cancel: { subscription.cancel() }) {}
  }
}
