import Foundation

public enum FolderListing {
  public typealias Entry = (name: String, directory: Bool, modified: TimeInterval?)

  public static func precedes(_ a: Entry, _ b: Entry, newestFirst: Bool = true) -> Bool {
    if a.directory != b.directory { return a.directory }
    if newestFirst, a.modified != b.modified {
      return (a.modified ?? -.infinity) > (b.modified ?? -.infinity)
    }
    return a.name.localizedStandardCompare(b.name) == .orderedAscending
  }

  public static func split<T>(_ entries: [T], name: KeyPath<T, String>, revealed: Bool = false)
    -> (shown: [T], hidden: Int)
  {
    guard !revealed else { return (entries, 0) }
    let shown = entries.filter { !$0[keyPath: name].hasPrefix(".") }
    return (shown, entries.count - shown.count)
  }

  public static func hiddenLabel(_ count: Int) -> String {
    "\(count) hidden \(count == 1 ? "item" : "items")"
  }

  public static let show = "Show"
}
