import AssetGrouping
import Composition
import CryptoKit
import Foundation
import HouseStyle
import ImageIO
import MarkdownRendering
import PreviewSupport
import UniformTypeIdentifiers

package struct CacheIdentity: Codable, Hashable, Sendable {
  let profile: UUID
  let account: String
  let fingerprint: String
  let path: String
}

package struct CachedFile: Codable, Sendable {
  package let stamp: FileStamp
  package let data: Data
  package let date: Date
}

package struct DocumentPreview: Codable, Equatable, Sendable {
  package var title: String?
  package var excerpt: String
  package init(_ source: String) {
    var lines = source.components(separatedBy: .newlines)[...]
    var metadataTitle: String?
    if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
      metadataTitle = lines.dropFirst().prefix(upTo: end).first { $0.hasPrefix("title:") }
        .map { String($0.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
      lines = lines.suffix(from: end + 1)
    }
    var paragraph: [String] = []
    var fenced = false
    var finished = false
    var heading: String?
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        fenced.toggle()
        continue
      }
      if fenced { continue }
      if heading == nil && line.hasPrefix("# ") { heading = String(line.dropFirst(2)) }
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("![") {
        if !paragraph.isEmpty { finished = true }
      } else if !finished {
        paragraph.append(line)
      }
    }
    func plain(_ text: String) -> String {
      (try? AttributedString(markdown: text)).map { String($0.characters) } ?? text
    }
    title = (heading ?? metadataTitle).map(plain)
    excerpt = String(plain(paragraph.joined(separator: " ")).prefix(320))
  }
}

package struct ReadDocument: Identifiable, Sendable {
  package let id = UUID()
  package let path: String
  package let file: CachedFile
  package var wordCount = 0
  package var source = ""
  package var token = ""
  package var codeBlocks: [String] = []
  package var html: String?
  package var title: String
  package var excerpt = ""
  package var details: [String: String] = [:]
  var cameraFields: [(String, String)] = []
  package var imageDetails: ImageDetails.Details {
    ImageDetails.interpret(pngText: details, flattened: cameraFields)
  }
  package var imagePrompt: String? { imageDetails.prompt }
  package var isHTML = false
  package var isVideo = false
  package var isImage = false
  package var changed = false
  package var position = ReadingPosition()
}

@MainActor package func plainTextPage(_ source: String, form: HouseForm) -> String {
  "<style>" + MarkdownRenderer.stylesheet + DocumentPaper(form: form).palette + "</style><article><pre>"
    + MarkdownRenderer.escaped(source) + "</pre></article>"
}

package enum Format: String, CaseIterable {
  case markdown, text, json, image, html, video, notebook, table
  package static func isDocument(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return markdown.descriptor.extensions.contains(ext) || text.descriptor.extensions.contains(ext)
  }
  var descriptor: PreviewDescriptor { descriptor(extendedImages: true) }
  func descriptor(extendedImages: Bool) -> PreviewDescriptor {
    let extensions: Set<String>
    switch self {
    case .markdown: extensions = PreviewFileTypes.markdown
    case .text: extensions = PreviewFileTypes.text
    case .notebook: extensions = PreviewFileTypes.notebook
    case .table: extensions = PreviewFileTypes.table
    case .html: extensions = PreviewFileTypes.html
    case .video: extensions = PreviewFileTypes.video
    case .json: extensions = PreviewFileTypes.json
    case .image: extensions = PreviewFileTypes.images(extended: extendedImages)
    }
    let limit: Int
    switch self {
    case .image: limit = PreviewLimits.original
    case .markdown, .html, .text: limit = PreviewLimits.document
    default: limit = StructuredPreview.limit
    }
    return .init(
      id: rawValue, title: rawValue.capitalized, extensions: extensions,
      maximumBytes: Int64(limit))
  }

  func render(
    path: String, file: CachedFile, token: String = UUID().uuidString, form: HouseForm? = nil
  ) async throws
    -> ReadDocument
  {
    var doc = ReadDocument(path: path, file: file, title: (path as NSString).lastPathComponent)
    if self == .video {
      doc.isVideo = true
      return doc
    }
    if self == .image {
      guard let source = CGImageSourceCreateWithData(file.data as CFData, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
      else {
        throw CompositionError("No image preview.")
      }
      doc.isImage = true
      doc.details = PNGTextReader.read(data: file.data)
      if let w = props[kCGImagePropertyPixelWidth as String],
        let h = props[kCGImagePropertyPixelHeight as String]
      {
        doc.details["Dimensions"] = "\(w) × \(h)"
      }
      doc.cameraFields = ImageDetails.flatten(props.filter { $0.key != kCGImagePropertyPNGDictionary as String })
      return doc
    }
    guard !file.data.contains(0), var source = String(data: file.data, encoding: .utf8) else {
      throw CompositionError("No text preview.")
    }
    if source.first == "\u{feff}" { source.removeFirst() }
    if self == .json {
      let value = try JSONSerialization.jsonObject(with: file.data, options: .fragmentsAllowed)
      source = String(
        decoding: try JSONSerialization.data(
          withJSONObject: value,
          options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]),
        as: UTF8.self)
    }
    doc.source = source
    switch self {
    case .html:
      doc.isHTML = true
      doc.html = source
    case .notebook: doc.html = try StructuredPreview.notebook(file.data)
    case .table:
      doc.html = try StructuredPreview.table(
        file.data, delimiter: path.lowercased().hasSuffix(".tsv") ? "\t" : ",")
    default: break
    }
    if self == .markdown {
      doc.wordCount = source.split(whereSeparator: \.isWhitespace).count
      let page = MarkdownRenderer.page(
        source,
        options: .init(
          referenceToken: token, images: .passthrough,
          enriched: file.data.count <= MarkdownRenderer.maximumEnrichedByteCount))
      doc.token = token
      doc.codeBlocks = page.codeBlocks
      doc.html = await MarkdownRenderer.body(page, palette: DocumentPaper(form: form ?? HousePalette.form).palette)
      let lines = source.split(whereSeparator: \.isNewline)
      if let heading = lines.first(where: { $0.hasPrefix("# ") }) {
        doc.title = String(heading.dropFirst(2))
      }
      doc.excerpt = String((lines.first { !$0.hasPrefix("#") } ?? "").prefix(200))
    }
    try Task.checkCancellation()
    return doc
  }
}

package struct AssetFolder: Sendable {
  package let document: String
  package let files: any RemoteFiles
  package init(document: String, files: any RemoteFiles) {
    self.document = document
    self.files = files
  }
  package func read(relative: String) async throws -> Data {
    guard !relative.hasPrefix("/"), !relative.contains("\\"), !relative.isEmpty,
      relative.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw CompositionError("Invalid asset path.") }
    let folder = try await files.resolve((document as NSString).deletingLastPathComponent)
    var parts = folder.split(separator: "/").map(String.init)
    for part in relative.split(separator: "/") {
      switch part {
      case ".": continue
      case "..":
        guard !parts.isEmpty else { throw CompositionError("Asset is outside the host root.") }
        parts.removeLast()
      default: parts.append(String(part))
      }
    }
    let target = try await files.resolve("/" + parts.joined(separator: "/"))
    guard target.hasPrefix("/"), !target.split(separator: "/").contains("..") else {
      throw CompositionError("Invalid asset path.")
    }
    return try await files.read(target, limit: Int(Format.image.descriptor.maximumBytes))
  }
}

struct ReadRequest {
  let path: String
  let file: CachedFile
  var form: HouseForm? = nil
}

@MainActor package struct Reader {
  package var extendedImages: Bool { prefs.value.enabled(PreviewPlugins.moreImages, host: profile.id) }
  let files: any RemoteFiles
  let cache: DocumentCache
  let registry: FilePreviewRegistry<ReadRequest, ReadDocument>
  let profile: Profile
  let identity: Identity
  let prefs: PreferenceStore<Preferences>
  let observers: Registry<DocumentObserver>
  let context: FeatureContext
  package func preview(path: String, stamp: FileStamp) async throws -> DocumentPreview? {
    guard ["markdown", "text"].contains(registry.descriptor(for: path)?.id ?? "") else {
      return nil
    }
    return try await cache.preview(
      .init(
        profile: profile.id, account: profile.account, fingerprint: identity.fingerprint, path: path
      ),
      stamp: stamp, files: files, saver: prefs.value.enabled("data-saver", host: profile.id))
  }
  package func thumbnail(path: String, stamp: FileStamp, limit: Int) async throws -> Data? {
    guard limit > 0 else { return nil }
    return try await cache.thumbnail(
      .init(
        profile: profile.id, account: profile.account, fingerprint: identity.fingerprint, path: path
      ),
      files: files, stamp: stamp, limit: limit)
  }
  package func save(position: ReadingPosition, path: String, excerpt: String? = nil) throws {
    try prefs.update { value in
      if let i = value.history.firstIndex(where: { $0.profile == profile.id && $0.path == path }) {
        value.history[i].position = position
        if let excerpt { value.history[i].excerpt = excerpt }
      }
    }
  }
  package func open(_ path: String) async throws -> ReadDocument {
    try await context.perform("Read document") { try await load(path) }
  }
  private func load(_ path: String) async throws -> ReadDocument {
    guard let descriptor = registry.descriptor(for: path) else {
      throw CompositionError("No preview for this format.")
    }
    let key = CacheIdentity(
      profile: profile.id, account: profile.account, fingerprint: identity.fingerprint, path: path)
    let entry: CachedFile
    if descriptor.id == Format.video.rawValue {
      entry = CachedFile(stamp: try await files.stat(path), data: Data(), date: Date())
    } else {
      entry = try await cache.load(key, files: files, limit: Int(descriptor.maximumBytes))
    }
    let preview = try await registry.open(
      filename: path, bytes: Int64(entry.data.count),
      request: .init(
        path: path, file: entry,
        form: prefs.value.enabled(PaperAppearance.plugin, host: profile.id) ? .paper : .standard))
    var doc = preview.content
    await preview.close()
    if doc.isImage {
      let folder = (path as NSString).deletingLastPathComponent
      let names = (try? await files.list(folder))?.filter { !$0.stamp.directory }.map(\.name) ?? []
      let owners = names.filter { AssetCompanionNames.isMedia($0, extendedImages: extendedImages) }
      let companions =
        AssetCompanionNames.groups(media: owners, files: names)[
          (path as NSString).lastPathComponent] ?? []
      var remaining = PreviewLimits.companionCharacters
      for name in companions.prefix(PreviewLimits.companions) where remaining > 0 {
        try Task.checkCancellation()
        let sidecar = (folder as NSString).appendingPathComponent(name)
        guard let data = try? await files.read(sidecar, limit: PreviewLimits.companionBytes),
          !data.contains(0), let text = String(data: data, encoding: .utf8)
        else { continue }
        let clipped = PreviewLimits.companionText(text, remaining: &remaining)
        if clipped == text, let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          for (key, value) in fields where value is String || value is NSNumber {
            doc.details[key] = String(describing: value)
          }
        } else {
          doc.details[name] = clipped
        }
      }
    }
    try Task.checkCancellation()
    if let previous = prefs.value.history.first(where: {
      $0.profile == profile.id && $0.path == path
    }) {
      doc.position = previous.position
      doc.changed = previous.stamp != entry.stamp
      if !doc.changed { doc.excerpt = previous.excerpt }
    }
    try context.checkActive()
    try prefs.update {
      for observer in observers.entries { observer.record(doc, &$0) }
      $0.record(
        .init(
          profile: profile.id, path: path, title: doc.title,
          plainTable: descriptor.id == "text"
            && Format.table.descriptor.extensions.contains(
              (path as NSString).pathExtension.lowercased())
            ? true : nil, excerpt: doc.excerpt,
          date: Date(), stamp: entry.stamp, position: doc.position))
    }
    return doc
  }
}

package func groupedRows(_ rows: [FileRow], extendedImages: Bool = true) -> [FileRow] {
  let names = rows.filter { !$0.stamp.directory }.map(\.name)
  let groups = AssetCompanionNames.groups(
    media: names.filter { AssetCompanionNames.isMedia($0, extendedImages: extendedImages) }, files: names)
  let companions = Set(groups.values.flatMap { $0 })
  return rows.compactMap { row in
    guard row.stamp.directory || !companions.contains(row.name) else { return nil }
    var owner = row
    owner.companions = groups[row.name] ?? []
    return owner
  }
}
