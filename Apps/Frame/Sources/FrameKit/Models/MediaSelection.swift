import Foundation

/// Normal selection follows the preview; Select mode can keep checked targets independent.
public struct MediaSelection: Equatable, Sendable {
  public private(set) var ids: Set<String> = []
  public private(set) var currentID: String?
  public init() {}

  public mutating func replace(with id: String?) {
    ids = id.map { [$0] } ?? []
    currentID = id
  }
  public mutating func update(ids: Set<String>, currentID: String?, keepingPreview: Bool = false) {
    self.ids = ids
    self.currentID = keepingPreview ? currentID : currentID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.sorted().first
  }
  public mutating func preview(_ id: String?, keepingSelection: Bool = false) {
    if keepingSelection { currentID = id; return }
    guard let id else { replace(with: nil); return }
    if !ids.contains(id) { replace(with: id) } else { currentID = id }
  }

  public static func nextPreview(in order: [String], current: String?, removing removed: Set<String>) -> String? {
    guard let current, let index = order.firstIndex(of: current) else { return order.first { !removed.contains($0) } }
    if !removed.contains(current) { return current }
    return order.dropFirst(index + 1).first { !removed.contains($0) }
      ?? order.prefix(index).last { !removed.contains($0) }
  }
  public mutating func reconcile(with orderedIDs: [String]) {
    let available = Set(orderedIDs)
    ids.formIntersection(available)
    if currentID.map({ ids.contains($0) }) != true {
      currentID = orderedIDs.first { ids.contains($0) }
    }
  }
}

/// Positional anchors are only valid until the grid's ordered files change.
public struct SelectionRangeAnchor: Sendable {
  public private(set) var index: Int?
  public init() {}
  public mutating func reset() { index = nil }
  public mutating func set(_ index: Int) { self.index = index }
  public mutating func range(to destination: Int, current: Int?, count: Int) -> ClosedRange<Int>? {
    guard count > 0 else { reset(); return nil }
    let target = min(count - 1, max(0, destination))
    let anchor = min(count - 1, max(0, index ?? current ?? target))
    index = anchor
    return min(anchor, target)...max(anchor, target)
  }
}
