import Foundation

/// The rules for the marker on files changed since they were last opened in Frame. Only file times are compared,
/// never the Mac's clock, so a remote host whose clock differs neither hides nor invents markers.
public enum ChangeTracking {
  /// A file is changed when its modification time is later than its folder's baseline and later than the
  /// modification time it had when it was last shown. Without a baseline nothing is marked.
  public static func isChanged(modified: Date?, baseline: Date?, opened: Date?) -> Bool {
    guard let modified, let baseline else { return false }
    return modified > max(baseline, opened ?? baseline)
  }

  /// A folder's baseline: the newest modification time among the files listed in it. An empty folder's baseline
  /// is the distant past, so anything added to it later is marked.
  public static func baseline(of files: [PhotoItem]) -> Date {
    files.compactMap(modificationDate).max() ?? .distantPast
  }

  /// The modification time a file's marker is judged by: the scan's on this Mac, the listing's for a remote file.
  public static func modificationDate(of photo: PhotoItem) -> Date? {
    if let remote = photo.remote { return parse(remote.entry.modified) }
    return photo.modifiedAt
  }

  private static let cache = ParsedTimes()

  /// Remote listings give ISO 8601 times, with or without fractional seconds. Each text is parsed once.
  public static func parse(_ text: String) -> Date? { cache.date(for: text) }

  fileprivate static func read(_ text: String) -> Date? {
    if let date = fractional.date(from: text) { return date }
    if let date = whole.date(from: text) { return date }
    // Six-digit fractions are trimmed to the milliseconds the formatter reads.
    guard let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) else { return nil }
    let digits = text[text.index(after: dot)..<end]
    return fractional.date(from: String(text[..<dot]) + "." + String(digits.prefix(3)) + String(text[end...]))
  }
  private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let whole: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

/// Listing times already parsed, bounded so a long session cannot grow it without limit.
private final class ParsedTimes: @unchecked Sendable {
  private let lock = NSLock()
  private var dates: [String: Date?] = [:]
  func date(for text: String) -> Date? {
    lock.lock()
    if let known = dates[text] { lock.unlock(); return known }
    lock.unlock()
    let date = ChangeTracking.read(text)
    lock.lock()
    if dates.count >= 50_000 { dates.removeAll() }
    dates[text] = date
    lock.unlock()
    return date
  }
}
