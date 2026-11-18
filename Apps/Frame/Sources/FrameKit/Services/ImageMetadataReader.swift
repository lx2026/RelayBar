import BridgeProtocol
import Foundation
import ImageIO

public enum ImageMetadataReader {
  public static func read(photo: PhotoItem, remoteClient: (any RemoteFileReading)? = nil,
                          remotePreview: (any RemotePreviewServing)? = nil,
                          videoMetadata: VideoMetadataReader = VideoMetadataReader()) async -> ImageMetadata {
    if photo.format.isDocument {
      return ImageMetadata(identity: [MetadataRow(label: "Type", value: photo.format.rawValue),
        MetadataRow(label: "File size", value: ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))])
    }
    if let remote = photo.remote {
      guard let remoteClient else { return ImageMetadata() }
      if photo.format.isVideo {
        var result: ImageMetadata
        if let local = await remoteClient.cachedMedia(photo) {
          result = await readEmbedded(photo: local, videoMetadata: videoMetadata)
          result.companions = await remoteClient.companionText(photo)
          result.sidecarText = result.companions.first { $0.name == photo.sidecar?.url.lastPathComponent }?.text
        } else { result = ImageMetadata(identity: identityRows(for: photo, properties: [:])) }
        result.identity.append(MetadataRow(label: "Source", value: remote.source.name))
        return result
      }
      var result: ImageMetadata
      do {
        guard let remotePreview else { throw BridgeError("Preview helper unavailable.") }
        let preview = try await remotePreview.preview(photo, pixels: 2048)
        let fields = preview.metadata ?? [:], text = preview.text ?? [:]
        result = ImageMetadata(identity: identityRows(for: photo, properties: [:]))
        for key in ["Dimensions", "Duration", "Codec", "Modified"] {
          if let value = fields[key], !value.isEmpty { result.identity.append(MetadataRow(label: key, value: value)) }
        }
        result.embedded = (fields.merging(text, uniquingKeysWith: { first, _ in first })).sorted { $0.key < $1.key }
          .map { MetadataRow(label: $0.key, value: $0.value) }
        let ai = parseAIMetadata(pngText: text, flattened: fields.map { ($0.key, $0.value) })
        result.prompt = ai.prompt; result.negativePrompt = ai.negativePrompt; result.aiGeneration = ai.rows
        result.sidecarText = preview.sidecar
        result.companions = preview.companions ?? []
      } catch {
        result = ImageMetadata(identity: identityRows(for: photo, properties: [:]))
        result.identity.append(MetadataRow(label: "Preview", value: error.localizedDescription))
      }
      result.identity.append(MetadataRow(label: "Source", value: remote.source.name))
      if !remote.entry.modified.isEmpty { result.identity.append(MetadataRow(label: "Remote modified", value: remote.entry.modified)) }
      return result
    }
    var result = await readEmbedded(photo: photo, videoMetadata: videoMetadata)
    result.companions = await Task.detached(priority: .userInitiated) {
      var remaining = 256_000, texts: [BridgeCompanionText] = []
      for file in photo.companions {
        guard remaining > 0 else { break }
        let text = String(SidecarReader.read(file).prefix(remaining))
        texts.append(BridgeCompanionText(name: file.url.lastPathComponent, text: text))
        remaining -= text.count
      }
      return texts
    }.value
    result.sidecarText = result.companions.first { $0.name == photo.sidecar?.url.lastPathComponent }?.text
    return result
  }

  private static func readEmbedded(photo: PhotoItem, videoMetadata: VideoMetadataReader) async -> ImageMetadata {
    if photo.format.isVideo {
      let video = await videoMetadata.info(for: photo)
      var rows = identityRows(for: photo, properties: [:])
      if let duration = video.durationLabel { rows.append(MetadataRow(label: "Duration", value: duration)) }
      if let width = video.width, let height = video.height {
        rows.append(MetadataRow(label: "Dimensions", value: "\(width) × \(height)"))
      }
      if let rate = video.frameRate { rows.append(MetadataRow(label: "Frame rate", value: String(format: "%.2f fps", rate))) }
      if let codec = video.codec { rows.append(MetadataRow(label: "Codec", value: codec)) }
      if let audio = video.audio { rows.append(MetadataRow(label: "Audio", value: audio)) }
      return ImageMetadata(identity: rows, embedded: video.embedded)
    }
    return await Task.detached(priority: .userInitiated) {
      readSynchronously(photo: photo)
    }.value
  }

  private static func readSynchronously(photo: PhotoItem) -> ImageMetadata {
    let properties = imageProperties(at: photo.url)
    let pngText = photo.format == .png ? ((try? PNGTextReader.read(from: photo.url)) ?? [:]) : [:]
    let flattened = flatten(properties)

    var metadata = ImageMetadata()
    metadata.identity = identityRows(for: photo, properties: properties)
    metadata.capture = captureRows(from: properties)
    metadata.embedded = embeddedRows(flattened: flattened, pngText: pngText)

    let ai = parseAIMetadata(pngText: pngText, flattened: flattened)
    metadata.prompt = ai.prompt
    metadata.negativePrompt = ai.negativePrompt
    metadata.aiGeneration = ai.rows
    return metadata
  }

  private static func imageProperties(at url: URL) -> [String: Any] {
    let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary)
        as? [String: Any]
    else {
      return [:]
    }
    return properties
  }

  private static func identityRows(for photo: PhotoItem, properties: [String: Any]) -> [MetadataRow]
  {
    let byteFormatter = ByteCountFormatter()
    byteFormatter.countStyle = .file
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .short

    var rows = [MetadataRow(label: "Type", value: photo.format.rawValue)]
    if let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
    {
      rows.append(MetadataRow(label: "Dimensions", value: "\(width) × \(height)"))
    }
    rows.append(
      MetadataRow(label: "File size", value: byteFormatter.string(fromByteCount: photo.fileSize)))
    if let createdAt = photo.createdAt {
      rows.append(MetadataRow(label: "Created", value: dateFormatter.string(from: createdAt)))
    }
    if let modifiedAt = photo.modifiedAt {
      rows.append(MetadataRow(label: "Modified", value: dateFormatter.string(from: modifiedAt)))
    }
    return rows
  }

  private static func captureRows(from properties: [String: Any]) -> [MetadataRow] {
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    var rows: [MetadataRow] = []

    append(
      "Camera",
      value: joined([
        tiff[kCGImagePropertyTIFFMake as String], tiff[kCGImagePropertyTIFFModel as String],
      ]), to: &rows)
    append("Lens", value: stringValue(exif[kCGImagePropertyExifLensModel as String]), to: &rows)
    append(
      "Focal length",
      value: numberWithSuffix(exif[kCGImagePropertyExifFocalLength as String], suffix: " mm"),
      to: &rows)
    append(
      "Exposure", value: exposureValue(exif[kCGImagePropertyExifExposureTime as String]), to: &rows)
    append(
      "Aperture",
      value: numberWithPrefix(exif[kCGImagePropertyExifFNumber as String], prefix: "ƒ/"), to: &rows)

    if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
      let iso = isoValues.first
    {
      append("ISO", value: iso.stringValue, to: &rows)
    }
    append(
      "Captured", value: stringValue(exif[kCGImagePropertyExifDateTimeOriginal as String]),
      to: &rows)
    return rows
  }

  private static func embeddedRows(flattened: [(String, String)], pngText: [String: String])
    -> [MetadataRow]
  {
    var rows: [MetadataRow] = []
    var seen = Set<String>()

    for (key, value) in pngText.sorted(by: {
      $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
    }) {
      let label = "PNG.\(key)"
      guard seen.insert(label).inserted else { continue }
      rows.append(MetadataRow(label: label, value: value))
    }
    for (key, value) in flattened where !value.isEmpty {
      guard seen.insert(key).inserted else { continue }
      rows.append(MetadataRow(label: key, value: value))
    }
    return rows
  }

  private struct AIResult {
    var prompt: String?
    var negativePrompt: String?
    var rows: [MetadataRow] = []
  }

  private static func parseAIMetadata(
    pngText: [String: String],
    flattened: [(String, String)]
  ) -> AIResult {
    var result = AIResult()
    let text = Dictionary(pngText.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })

    if let parameters = text["parameters"] {
      let parsed = parseAutomatic1111(parameters)
      result.prompt = parsed.prompt
      result.negativePrompt = parsed.negativePrompt
      result.rows.append(contentsOf: parsed.rows)
    }

    if result.prompt == nil, let prompt = firstValue(in: text, keys: ["prompt", "description"]) {
      if prompt.trimmingCharacters(in: .whitespacesAndNewlines).first != "{" {
        result.prompt = prompt
      }
    }
    if result.negativePrompt == nil {
      result.negativePrompt = firstValue(in: text, keys: ["negative prompt", "negative_prompt"])
    }

    let directMappings = [
      ("Model", ["model", "checkpoint"]),
      ("Seed", ["seed"]),
      ("Sampler", ["sampler"]),
      ("Steps", ["steps"]),
      ("CFG scale", ["cfg scale", "cfg_scale", "guidance"]),
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
    return result
  }

  private static func parseAutomatic1111(_ value: String) -> AIResult {
    let lines = value.components(separatedBy: .newlines)
    guard let settingsIndex = lines.lastIndex(where: { $0.hasPrefix("Steps:") }) else {
      return AIResult(
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
    return AIResult(
      prompt: prompt.isEmpty ? nil : prompt, negativePrompt: negativePrompt, rows: rows)
  }

  private static func flatten(_ dictionary: [String: Any]) -> [(String, String)] {
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

  private static func append(_ label: String, value: String?, to rows: inout [MetadataRow]) {
    guard let value, !value.isEmpty else { return }
    rows.append(MetadataRow(label: label, value: value))
  }

  private static func firstValue(in dictionary: [String: String], keys: [String]) -> String? {
    keys.compactMap { dictionary[$0] }.first(where: { !$0.isEmpty })
  }

  private static func joined(_ values: [Any?]) -> String? {
    let pieces = values.compactMap(stringValue).filter { !$0.isEmpty }
    return pieces.isEmpty ? nil : pieces.joined(separator: " ")
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String: return value
    case let value as NSNumber: return value.stringValue
    case let value as Date: return ISO8601DateFormatter().string(from: value)
    default: return nil
    }
  }

  private static func numberWithSuffix(_ value: Any?, suffix: String) -> String? {
    guard let number = value as? NSNumber else { return nil }
    return "\(number.stringValue)\(suffix)"
  }

  private static func numberWithPrefix(_ value: Any?, prefix: String) -> String? {
    guard let number = value as? NSNumber else { return nil }
    return "\(prefix)\(number.stringValue)"
  }

  private static func exposureValue(_ value: Any?) -> String? {
    guard let number = value as? NSNumber else { return nil }
    let seconds = number.doubleValue
    guard seconds > 0 else { return nil }
    if seconds < 1 {
      return "1/\(Int((1 / seconds).rounded())) s"
    }
    return "\(number.stringValue) s"
  }
}
