import PreviewSupport
import BridgeProtocol
import Foundation
import HouseStyle
import MarkdownRendering

actor DocumentParser {
  /// `paper` is read on the main actor by the caller; the standard form resolves system colours.
  func page(_ data: Data, extension ext: String, referenceToken: String, source: Bool = false, paper: DocumentPaper) throws -> (html: String, hasOutline: Bool) {
    try Task.checkCancellation()
    let page = try DocumentHTML.preparedPage(data, extension: ext, referenceToken: referenceToken, source: source, paper: paper)
    // A cancelled render returns an empty page, which must not be shown as the document.
    try Task.checkCancellation()
    return page
  }
}

public typealias DocumentPaper = HouseStyle.DocumentPaper

public enum DocumentHTML {
  /// `referenceToken` is carried by the page's Copy links so the renderer can tell them from links a document wrote.
  public static func markdown(_ source: String, referenceToken: String, paper: DocumentPaper) -> String {
    renderedMarkdown(source, referenceToken: referenceToken, paper: paper).html
  }
  private static func renderedMarkdown(_ source: String, referenceToken: String, paper: DocumentPaper) -> (html: String, hasOutline: Bool) {
    let enriched = source.utf8.count <= MarkdownRenderer.maximumEnrichedByteCount
    let page = MarkdownRenderer.page(source, options: .init(referenceToken: referenceToken, images: .passthrough, enriched: enriched))
    return (MarkdownRenderer.body(page, palette: palette(paper)), page.outlineHeadingCount >= 2)
  }
  @MainActor public static func markdown(_ source: String, referenceToken: String) -> String {
    markdown(source, referenceToken: referenceToken, paper: .current)
  }
  /// `asSource` shows Markdown and HTML as their own text, through the same path as any other text file.
  public static func page(_ data: Data, extension ext: String, referenceToken: String, source asSource: Bool = false,
                          paper: DocumentPaper) throws -> String {
    try preparedPage(data, extension: ext, referenceToken: referenceToken, source: asSource, paper: paper).html
  }
  fileprivate static func preparedPage(_ data: Data, extension ext: String, referenceToken: String, source asSource: Bool,
                                       paper: DocumentPaper) throws -> (html: String, hasOutline: Bool) {
    guard data.count <= DocumentResources.documentLimit else { throw BridgeError("Document exceeds 10 MiB.") }
    guard !data.contains(0), let source = String(data: data, encoding: .utf8) else { throw BridgeError("No text preview.") }
    if !asSource, PreviewFileTypes.markdown.contains(ext.lowercased()) { return renderedMarkdown(source, referenceToken: referenceToken, paper: paper) }
    if !asSource, PreviewFileTypes.html.contains(ext.lowercased()) { return (source, false) }
    return ("<style>\(theme(paper))</style><article><pre>\(MarkdownRenderer.escaped(source))</pre></article>", false)
  }
  @MainActor public static func page(_ data: Data, extension ext: String, referenceToken: String, source asSource: Bool = false) throws -> String {
    try page(data, extension: ext, referenceToken: referenceToken, source: asSource, paper: .current)
  }
  /// Frame's green-accented colours over the shared reading design, on the reader column's paper.
  /// `--frame-page` marks the pages whose paper follows a later change of form.
  public static func palette(_ paper: DocumentPaper) -> String {
    paper.palette
  }
  @MainActor public static var palette: String { palette(.current) }
  public static func theme(_ paper: DocumentPaper) -> String { MarkdownRenderer.stylesheet + palette(paper) }
  @MainActor public static var theme: String { theme(.current) }

  /// The page colour alone, laid over a page already on show when the form changes or after a page has loaded.
  public static func paperStyle(_ paper: DocumentPaper) -> String {
    ":root{--md-bg:\(paper.light)}@media(prefers-color-scheme:dark){:root{--md-bg:\(paper.dark)}}"
  }
}
