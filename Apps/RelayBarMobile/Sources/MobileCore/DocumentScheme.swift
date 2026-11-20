import PreviewSupport
import Foundation
import UniformTypeIdentifiers

/// A unique origin per page. Keeping the document's real directory in its URL allows WebKit
/// to resolve stylesheet, font and image references (including parent segments) normally.
package actor DocumentScheme {
  package nonisolated let mainURL: URL
  private var requested: Set<String> = []
  private var assets: [String: Data] = [:]
  private var totalBytes = 0
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
        bytes = try await asset(at: url.path(percentEncoded: false), files: files)
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

  private func asset(at path: String, files: any RemoteFiles) async throws -> Data {
    if let data = assets[path] { return data }
    let directory = (mainURL.path(percentEncoded: false) as NSString).deletingLastPathComponent
    guard !path.split(separator: "/").contains(".."), !path.contains("\\"),
      path.hasPrefix(directory == "/" ? "/" : directory + "/")
    else { throw URLError(.noPermissionsToReadFile) }
    guard requested.contains(path) || requested.count < PreviewLimits.requests
    else { throw URLError(.dataLengthExceedsMaximum) }
    requested.insert(path)
    let root = try await files.resolve(directory)
    let target = try await files.resolve(path)
    guard target.hasPrefix(root == "/" ? "/" : root + "/") else { throw URLError(.noPermissionsToReadFile) }
    let limit = min(PreviewLimits.asset, PreviewLimits.page - totalBytes)
    let data = try await files.read(target, limit: limit)
    // Another request for this path may have finished during the read.
    if let cached = assets[path] { return cached }
    guard data.count <= limit, data.count <= PreviewLimits.page - totalBytes
    else { throw URLError(.dataLengthExceedsMaximum) }
    assets[path] = data
    totalBytes += data.count
    return data
  }
}
