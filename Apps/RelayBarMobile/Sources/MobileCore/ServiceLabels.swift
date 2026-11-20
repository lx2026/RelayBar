import PreviewSupport
import Composition
import Foundation
import Network

package struct ServiceLabeller: Identifiable {
  package let id: String
  package let read: @Sendable (URL, [ProxyConfiguration], String?) async -> String?
}
package enum ServiceLabellers: ServiceKey { package typealias Value = Registry<ServiceLabeller> }
struct TitleFeature: Feature {
  @Need(ServiceLabellers.self) var registry
  func run(_ context: FeatureContext) async throws {
    try registry.register(.init(id: "title", read: fetchTitle), in: context)
  }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
private func fetchTitle(_ url: URL, _ proxies: [ProxyConfiguration], _ userAgent: String?) async
  -> String?
{
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForResource = 3
  config.timeoutIntervalForRequest = 3
  config.connectionProxyDictionary = [:]
  config.proxyConfigurations = proxies
  let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
  defer { session.invalidateAndCancel() }
  do {
    var request = URLRequest(url: url)
    if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      return nil
    }
    var buffer = Data()
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count == WebsiteName.byteLimit { break }
    }
    let token = userAgent?.components(separatedBy: "RelayBar/").last
    return WebsiteName.recognizing(status: http.statusCode, contentType: http.mimeType, body: buffer, excluding: token)
  } catch { return nil }
}
