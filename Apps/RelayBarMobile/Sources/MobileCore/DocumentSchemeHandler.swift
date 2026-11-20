import Foundation
import WebKit

@MainActor package final class DocumentSchemeHandler: NSObject, WKURLSchemeHandler {
  package let scheme: DocumentScheme
  package var html: String
  package var files: (any RemoteFiles)?
  private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]

  package init(path: String, html: String, files: (any RemoteFiles)?, folderOnly: Bool = false) {
    scheme = .init(path: path, folderOnly: folderOnly)
    self.html = html
    self.files = files
  }

  package func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) { start(task) }
  package func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { stop(task) }

  func start(_ task: any WKURLSchemeTask) {
    let key = ObjectIdentifier(task)
    requests[key] = Task {
      defer { requests[key] = nil }
      do {
        guard let url = task.request.url else { throw URLError(.badURL) }
        let (response, data) = try await scheme.response(for: url, html: html, files: files)
        try Task.checkCancellation()
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
      } catch { if !Task.isCancelled { task.didFailWithError(error) } }
    }
  }

  func stop(_ task: any WKURLSchemeTask) {
    requests.removeValue(forKey: ObjectIdentifier(task))?.cancel()
  }
}
