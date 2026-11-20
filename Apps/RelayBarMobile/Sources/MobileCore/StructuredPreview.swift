import Composition
import Foundation
import MarkdownRendering

enum StructuredPreview {
  static let limit = 2 << 20
  private static func bounded(_ data: Data) throws {
    guard data.count <= limit else { throw CompositionError("This preview exceeds 2 MiB.") }
  }

  static func table(_ data: Data, delimiter: Character) throws -> String {
    try bounded(data)
    guard var text = String(data: data, encoding: .utf8) else {
      throw CompositionError("Expected UTF-8 text.")
    }
    if text.first == "\u{feff}" { text.removeFirst() }
    var body = ""
    var field = ""
    var row = ""
    var quoted = false
    var afterQuote = false
    var header = true
    var cells = 0
    func finishField() throws {
      cells += 1
      guard cells <= 100_000 else { throw CompositionError("This table exceeds 100,000 cells.") }
      let tag = header ? "th" : "td"
      row += "<\(tag)>\(MarkdownRenderer.escaped(field))</\(tag)>"
      field = ""
      afterQuote = false
    }
    func finishRow() throws {
      try finishField()
      body += "<tr>" + row + "</tr>"
      row = ""
      header = false
    }
    for ch in text {
      if quoted {
        if ch == "\"" {
          quoted = false
          afterQuote = true
        } else {
          field.append(ch)
        }
      } else if ch == delimiter {
        try finishField()
      } else if ch.isNewline {
        try finishRow()
      } else if ch == "\"", field.isEmpty || afterQuote {
        if afterQuote { field.append(ch) }
        afterQuote = false
        quoted = true
      } else {
        guard !afterQuote else { throw CompositionError("Invalid quoted table cell.") }
        field.append(ch)
      }
    }
    guard !quoted else { throw CompositionError("Unclosed quoted table cell.") }
    if !row.isEmpty || !field.isEmpty || afterQuote { try finishRow() }
    return "<style>" + MarkdownRenderer.stylesheet
      + "td,th{white-space:pre}th{position:sticky;top:0;background:var(--md-bg)}</style><article class='markdown'><div style='overflow:auto'><table>"
      + body + "</table></div></article>"
  }

  static func notebook(_ data: Data) throws -> String {
    try bounded(data)
    guard let book = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let cells = book["cells"] as? [[String: Any]], cells.count <= 2048
    else { throw CompositionError("Expected a notebook with at most 2,048 cells.") }
    func string(_ value: Any?) -> String {
      value as? String ?? (value as? [String])?.joined() ?? ""
    }
    let info = (book["metadata"] as? [String: Any])?["language_info"] as? [String: Any]
    let language = (info?["name"] as? String ?? "python").filter { $0.isLetter || $0.isNumber }
    var html =
      "<style>" + MarkdownRenderer.stylesheet
      + "article{padding-bottom:4px}figure a{display:none}</style>"
    for cell in cells {
      try Task.checkCancellation()
      let source = string(cell["source"])
      if cell["cell_type"] as? String == "markdown" {
        html += MarkdownRenderer.page(source).html
      } else if cell["cell_type"] as? String == "code" {
        let fence = String(
          repeating: "`",
          count: 1 + max(2, source.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0))
        html += MarkdownRenderer.page(fence + language + "\n" + source + "\n" + fence).html
        for output in cell["outputs"] as? [[String: Any]] ?? [] {
          let mime = output["data"] as? [String: Any]
          if let type = ["image/png", "image/jpeg"].first(where: { mime?[$0] != nil }),
            let image = Data(base64Encoded: string(mime?[type]), options: .ignoreUnknownCharacters)
          {
            html +=
              "<article><img alt='Cell output' src='data:\(type);base64,\(image.base64EncodedString())'></article>"
          } else {
            let text = string(output["text"] ?? mime?["text/plain"] ?? output["traceback"])
            html += "<article><pre>" + MarkdownRenderer.escaped(text) + "</pre></article>"
          }
        }
      } else {
        html += "<article><pre>" + MarkdownRenderer.escaped(source) + "</pre></article>"
      }
    }
    return html
  }
}
