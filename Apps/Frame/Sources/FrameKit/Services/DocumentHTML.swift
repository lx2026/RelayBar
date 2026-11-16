import BridgeProtocol
import Foundation
import MarkdownRendering

actor DocumentParser {
  func page(_ data: Data, extension ext: String, referenceToken: String) throws -> String {
    try Task.checkCancellation()
    let page = try DocumentHTML.page(data, extension: ext, referenceToken: referenceToken)
    // A cancelled render returns an empty page, which must not be shown as the document.
    try Task.checkCancellation()
    return page
  }
}

public enum DocumentHTML {
  /// `referenceToken` is carried by the page's Copy links so the renderer can tell them from links a document wrote.
  public static func markdown(_ source: String, referenceToken: String) -> String {
    let enriched = source.utf8.count <= MarkdownRenderer.maximumEnrichedByteCount
    let page = MarkdownRenderer.page(source, options: .init(referenceToken: referenceToken, images: .passthrough, enriched: enriched))
    return MarkdownRenderer.body(page, palette: palette)
  }
  public static func page(_ data: Data, extension ext: String, referenceToken: String) throws -> String {
    guard data.count <= DocumentResources.documentLimit else { throw BridgeError("Document exceeds 10 MiB.") }
    guard !data.contains(0), let source = String(data: data, encoding: .utf8) else { throw BridgeError("No text preview.") }
    if ["md", "markdown"].contains(ext.lowercased()) { return markdown(source, referenceToken: referenceToken) }
    if ["html", "htm"].contains(ext.lowercased()) { return source }
    return "<style>\(theme)</style><article><pre>\(MarkdownRenderer.escaped(source))</pre></article>"
  }
  /// Frame's paper-and-green colours over the shared reading design.
  public static let palette = """
  :root{--md-bg:#fafaf8;--md-text:#242821;--md-secondary:rgba(36,40,33,.6);--md-link:#3c6a42;--md-accent-rgb:60,106,66}
  @media(prefers-color-scheme:dark){:root{--md-bg:#20221f;--md-text:#e3e6df;--md-secondary:rgba(227,230,223,.6);--md-link:#a2c6a2;--md-accent-rgb:98,148,104}}
  """
  public static let theme = MarkdownRenderer.stylesheet + palette
}
