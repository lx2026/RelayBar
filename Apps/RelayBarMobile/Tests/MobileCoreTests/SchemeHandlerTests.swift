import Foundation
import Testing
import WebKit

@testable import MobileCore
@testable import MobileUI

private final class AssetTask: NSObject, WKURLSchemeTask {
  let request: URLRequest
  var response: URLResponse?
  var bytes = Data()
  var finished = false
  var error: Error?
  init(_ url: URL) { request = URLRequest(url: url) }
  func didReceive(_ response: URLResponse) { self.response = response }
  func didReceive(_ data: Data) { bytes.append(data) }
  func didFinish() { finished = true }
  func didFailWithError(_ error: any Error) { self.error = error }
}

@Test @MainActor func webKitAssetCallbacksAndStop() async throws {
  let demo = try DemoHost()
  let handler = DocumentSchemeHandler(
    path: DemoHost.report, html: "<article>Report</article>", files: demo)
  let url = try #require(
    URL(string: "samples/grid-0031.png", relativeTo: handler.scheme.mainURL)?.absoluteURL)
  let cancelled = AssetTask(url)
  handler.start(cancelled)
  handler.stop(cancelled)
  let task = AssetTask(url)
  handler.start(task)
  let until = ContinuousClock.now + .seconds(2)
  while !task.finished && task.error == nil && ContinuousClock.now < until {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(task.finished && task.response?.mimeType == "image/png")
  #expect(task.bytes == (try demo.read(DemoHost.image, limit: 2 << 20)))
  #expect(!cancelled.finished && cancelled.response == nil && cancelled.error == nil)
}
