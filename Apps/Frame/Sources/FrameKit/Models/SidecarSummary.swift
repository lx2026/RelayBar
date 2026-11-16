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
    func value(_ aliases: [String]) -> String? {
      for alias in aliases {
        guard let key = object.keys.sorted().first(where: { $0.lowercased() == alias }),
              let value = object[key], !(value is NSNull) else { continue }
        if let string = value as? String, !string.isEmpty { return String(string.prefix(8_000)) }
        if let number = value as? NSNumber { return number.stringValue }
      }
      return nil
    }
    prompt = value(["prompt", "positive_prompt", "positive prompt"])
    negativePrompt = value(["negative_prompt", "negative prompt"])
    let fields: [(String, [String])] = [
      ("Model", ["model", "model_name"]), ("Seed", ["seed"]), ("Steps", ["steps"]),
      ("Sampler", ["sampler", "sampler_name"]), ("Guidance", ["cfg_scale", "cfg", "guidance_scale"]),
      ("Width", ["width"]), ("Height", ["height"])
    ]
    rows = fields.compactMap { title, aliases in value(aliases).map { MetadataRow(label: title, value: $0) } }
  }
}
