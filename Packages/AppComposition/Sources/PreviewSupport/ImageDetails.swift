import Foundation

public struct MetadataRow: Identifiable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let value: String

  public init(label: String, value: String) {
    self.id = "\(label):\(value)"
    self.label = label
    self.value = value
  }
}

public enum ImageDetails {
  public static let promptLabel = "Prompt"
  public static let negativeLabel = "Negative prompt"

  public struct Details: Sendable {
    public var prompt: String?
    public var negativePrompt: String?
    public var rows: [MetadataRow] = []
    public var capture: [MetadataRow] = []
    public var prompts: [MetadataRow] {
      [prompt.map { MetadataRow(label: ImageDetails.promptLabel, value: $0) },
       negativePrompt.map { MetadataRow(label: ImageDetails.negativeLabel, value: $0) }].compactMap { $0 }
    }
    public var ordered: [MetadataRow] { prompts + rows + capture }
  }

  public static func interpret(
    pngText: [String: String],
    flattened: [(String, String)]
  ) -> Details {
    var result = Details()
    let text = Dictionary(pngText.sorted { $0.key < $1.key }.map { ($0.key.lowercased(), $0.value) },
                          uniquingKeysWith: { first, _ in first })

    if let parameters = text["parameters"] {
      let parsed = parseAutomatic1111(parameters)
      result.prompt = parsed.prompt
      result.negativePrompt = parsed.negativePrompt
      result.rows.append(contentsOf: parsed.rows)
    }

    if result.prompt == nil, let prompt = firstValue(in: text, keys: ["prompt", "positive_prompt", "positive prompt", "description"]) {
      if prompt.trimmingCharacters(in: .whitespacesAndNewlines).first != "{" {
        result.prompt = prompt
      }
    }
    if result.negativePrompt == nil {
      result.negativePrompt = firstValue(in: text, keys: ["negative prompt", "negative_prompt"])
    }

    let directMappings = [
      ("Model", ["model", "checkpoint", "model_name"]),
      ("Template", ["template"]),
      ("Seed", ["seed"]),
      ("Sampler", ["sampler", "sampler_name"]),
      ("Steps", ["steps"]),
      ("CFG scale", ["cfg scale", "cfg_scale", "guidance", "cfg", "guidance_scale"]),
      ("Width", ["width"]), ("Height", ["height"]),
      ("Source", ["software", "source"]),
    ]
    var existingLabels = Set(result.rows.map(\.label))
    for (label, keys) in directMappings {
      if let value = firstValue(in: text, keys: keys), existingLabels.insert(label).inserted {
        result.rows.append(MetadataRow(label: label, value: value))
      }
    }

    if text["workflow"] != nil
      || (text["prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines).first == "{")
    {
      if existingLabels.insert("Source").inserted {
        result.rows.append(MetadataRow(label: "Source", value: "ComfyUI"))
      }
    }

    if result.prompt == nil {
      let candidates = flattened.filter {
        let key = $0.0.lowercased()
        return key.contains("description") || key.contains("usercomment")
      }
      result.prompt = candidates.first?.1
    }
    if let first = result.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).first,
       first == "{" || first == "[" { result.prompt = nil }
    result.capture = cameraRows(flattened)
    return result
  }

  private static func parseAutomatic1111(_ value: String) -> Details {
    let lines = value.components(separatedBy: .newlines)
    guard let settingsIndex = lines.lastIndex(where: { $0.hasPrefix("Steps:") }) else {
      return Details(
        prompt: value.trimmingCharacters(in: .whitespacesAndNewlines), negativePrompt: nil)
    }

    let contentLines = Array(lines[..<settingsIndex])
    let negativeIndex = contentLines.firstIndex(where: { $0.hasPrefix("Negative prompt:") })
    let promptLines = negativeIndex.map { Array(contentLines[..<$0]) } ?? contentLines
    let prompt = promptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

    var negativePrompt: String?
    if let negativeIndex {
      var negativeLines = Array(contentLines[negativeIndex...])
      negativeLines[0] = String(negativeLines[0].dropFirst("Negative prompt:".count))
      let value = negativeLines.joined(separator: "\n").trimmingCharacters(
        in: .whitespacesAndNewlines)
      negativePrompt = value.isEmpty ? nil : value
    }

    var rows: [MetadataRow] = []
    for component in lines[settingsIndex].split(separator: ",") {
      let pair = component.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard pair.count == 2 else { continue }
      rows.append(MetadataRow(label: pair[0], value: pair[1]))
    }
    return Details(
      prompt: prompt.isEmpty ? nil : prompt, negativePrompt: negativePrompt, rows: rows)
  }

  private static func cameraRows(_ flattened: [(String, String)]) -> [MetadataRow] {
    func field(_ key: String) -> String? {
      flattened.first { $0.0 == key || $0.0.hasSuffix("." + key) }?.1
    }
    let camera = [field("Make"), field("Model")].compactMap { $0 }.joined(separator: " ")
    let exposure = field("ExposureTime").flatMap(Double.init).flatMap { seconds -> String? in
      guard seconds.isFinite, seconds > 0 else { return nil }
      if seconds < 1 { return String(format: "1/%.0f s", (1 / seconds).rounded()) }
      return String(format: "%g s", seconds)
    }
    let fields: [(String, String?)] = [
      ("Camera", camera), ("Lens", field("LensModel")),
      ("Focal length", field("FocalLength").map { $0 + " mm" }), ("Exposure", exposure),
      ("Aperture", field("FNumber").map { "ƒ/" + $0 }),
      ("ISO", field("ISOSpeedRatings") ?? field("PhotographicSensitivity")), ("Captured", field("DateTimeOriginal"))
    ]
    return fields.compactMap { label, value in
      guard let value, !value.isEmpty else { return nil }
      return MetadataRow(label: label, value: value)
    }
  }

  public static func flatten(_ dictionary: [String: Any]) -> [(String, String)] {
    var rows: [(String, String)] = []

    func visit(_ value: Any, path: String) {
      if let dictionary = value as? [String: Any] {
        for key in dictionary.keys.sorted() {
          visit(dictionary[key] as Any, path: path.isEmpty ? key : "\(path).\(key)")
        }
      } else if let array = value as? [Any] {
        let values = array.compactMap(stringValue)
        if !values.isEmpty { rows.append((path, values.joined(separator: ", "))) }
      } else if let value = stringValue(value), !value.isEmpty {
        rows.append((path, value))
      }
    }

    visit(dictionary, path: "")
    return rows
  }

  private static func firstValue(in dictionary: [String: String], keys: [String]) -> String? {
    keys.compactMap { dictionary[$0] }.first(where: { !$0.isEmpty })
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String: return value
    case let value as NSNumber: return value.stringValue
    case let value as Date: return ISO8601DateFormatter().string(from: value)
    default: return nil
    }
  }

}
