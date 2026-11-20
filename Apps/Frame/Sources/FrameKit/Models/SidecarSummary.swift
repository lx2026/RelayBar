import PreviewSupport
import Foundation

/// A deliberately small, source-specific summary. Nested workflows remain in raw JSON.
/// These values never overwrite or merge with embedded metadata.
public struct SidecarSummary: Equatable, Sendable {
  public let prompt: String?
  public let negativePrompt: String?
  public let rows: [MetadataRow]
  public var hasGeneration: Bool { prompt != nil || negativePrompt != nil || !rows.isEmpty }

  public init(text: String?) {
    let object = text.flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    let fields = object.compactMapValues { value -> String? in
      if let text = value as? String { return String(text.prefix(8_000)) }
      return (value as? NSNumber)?.stringValue
    }
    let details = ImageDetails.interpret(pngText: fields, flattened: [])
    prompt = details.prompt
    negativePrompt = details.negativePrompt
    rows = details.rows
  }
}
