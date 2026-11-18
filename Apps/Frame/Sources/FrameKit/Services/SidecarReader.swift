import Foundation

public enum SidecarReader {
  public static let maximumBytes = 2 * 1_024 * 1_024
  /// Shown in place of a companion that is not text.
  public static let binaryCompanionText = "No text preview."

  /// The file's whole text for searching: not reformatted and not shortened for display.
  /// Nil for a file that is too large or is not text; throws when the file cannot be read.
  public static func searchableText(_ file: AssetFile) throws -> String? {
    try file.validate()
    guard file.size <= maximumBytes else { return nil }
    let handle = try FileHandle(forReadingFrom: file.url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes, !data.contains(0) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func read(_ file: AssetFile) -> String {
    do {
      try file.validate()
      guard file.size <= maximumBytes else { return RelayRemoteClient.oversizedCompanionText }
      let handle = try FileHandle(forReadingFrom: file.url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
      guard data.count <= maximumBytes else { throw AssetError(RelayRemoteClient.oversizedCompanionText) }
      let text: String
      if file.url.pathExtension.lowercased() == "json" {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        text = String(decoding: pretty, as: UTF8.self)
      } else {
        guard !data.contains(0), let decoded = String(data: data, encoding: .utf8) else { return binaryCompanionText }
        text = decoded
      }
      // Keep SwiftUI text layout bounded even for huge generated workflows.
      return text.count > 24_000 ? String(text.prefix(24_000)) + "\n…" : text
    } catch { return RelayRemoteClient.unreadableCompanionPrefix + error.localizedDescription }
  }
}
