import Foundation
import UniformTypeIdentifiers

/// A unique origin per page. Keeping the document's real directory in its URL allows WebKit
/// to resolve stylesheet, font and image references (including parent segments) normally.
package struct DocumentScheme: Sendable {
  package let mainURL: URL
  let folderOnly: Bool
  package init(path: String, folderOnly: Bool = false) {
    self.folderOnly = folderOnly
    var components = URLComponents()
    components.scheme = "relay-document"
    components.host = UUID().uuidString.lowercased()
    components.path = path.hasPrefix("/") ? path : "/" + path
    mainURL = components.url!
  }
  package func response(for url: URL, html: String, files: (any RemoteFiles)?) async throws -> (
    URLResponse, Data
  ) {
    guard url.scheme == mainURL.scheme, url.host == mainURL.host, url.user == nil, url.port == nil
    else { throw URLError(.badURL) }
    let bytes: Data
    let type: String
    if url == mainURL {
      bytes = Data(html.utf8)
      type = "text/html"
    } else {
      guard let files else { throw URLError(.notConnectedToInternet) }
      if folderOnly {
        let directory = (mainURL.path(percentEncoded: false) as NSString).deletingLastPathComponent
        let root = try await files.resolve(directory)
        let path = url.path(percentEncoded: false)
        guard !path.split(separator: "/").contains(".."), !path.contains("\\"),
          path.hasPrefix(directory == "/" ? "/" : directory + "/")
        else { throw URLError(.noPermissionsToReadFile) }
        let target = try await files.resolve(path)
        guard target.hasPrefix(root == "/" ? "/" : root + "/") else {
          throw URLError(.noPermissionsToReadFile)
        }
        bytes = try await files.read(target, limit: 100 << 20)
      } else {
        bytes = try await AssetFolder(document: "/page", files: files).read(
          relative: String(url.path(percentEncoded: false).dropFirst()))
      }
      type =
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        ?? "application/octet-stream"
    }
    return (
      .init(
        url: url, mimeType: type, expectedContentLength: bytes.count,
        textEncodingName: type.hasPrefix("text/") ? "utf-8" : nil), bytes
    )
  }
}
