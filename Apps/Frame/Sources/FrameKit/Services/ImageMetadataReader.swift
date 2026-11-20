import PreviewSupport
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
        let ai = ImageDetails.interpret(pngText: text, flattened: fields.map { ($0.key, $0.value) })
        result.capture = ai.capture
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
      var remaining = PreviewLimits.companionCharacters, texts: [BridgeCompanionText] = []
      for file in photo.companions.prefix(PreviewLimits.companions) {
        guard remaining > 0 else { break }
        let text = PreviewLimits.companionText(SidecarReader.read(file), remaining: &remaining)
        texts.append(BridgeCompanionText(name: file.url.lastPathComponent, text: text))
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
    let flattened = ImageDetails.flatten(properties.filter { $0.key != kCGImagePropertyPNGDictionary as String })

    var metadata = ImageMetadata()
    metadata.identity = identityRows(for: photo, properties: properties)
    metadata.embedded = embeddedRows(flattened: flattened, pngText: pngText)

    let ai = ImageDetails.interpret(pngText: pngText, flattened: flattened)
    metadata.capture = ai.capture
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
}
