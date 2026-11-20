import Foundation
import RelayTransport
import RelayWebRoutes

extension DemoHost: RouteStreamOpener {
  static let referenceHost = "reference.invalid"  // Reserved demo name, served in process.
  package var routeOpener: (any RouteStreamOpener)? { self }
  package var isReconnecting: Bool { false }
  package func withRouteStream<R: Sendable>(
    host: String, port: UInt16,
    _ body: @escaping @Sendable (RouteStream) async throws -> R
  ) async throws -> R {
    guard [80, 6006, notebookPort].contains(port) else { throw TransportError.connectionRefused }
    let reference = port == 80 ? try read(Self.image, limit: 2 << 20) : nil
    let request = DemoRequest(
      port: port, requiresLocalhost: port == notebookPort, reference: reference)
    return try await body(
      RouteStream(
        receive: { await request.receive() },
        write: { await request.write($0) }, finishWriting: {}))
  }
}

private actor DemoRequest {
  let port: UInt16
  var head = Data()
  var reply: Data?
  var finished = false
  var waiting: CheckedContinuation<Data?, Never>?
  let requiresLocalhost: Bool
  let reference: Data?
  init(port: UInt16, requiresLocalhost: Bool, reference: Data?) {
    self.reference = reference
    self.port = port
    self.requiresLocalhost = requiresLocalhost
  }
  func receive() async -> Data? {
    if let reply {
      self.reply = nil
      return reply
    }
    if finished || Task.isCancelled { return nil }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { waiting = $0 }
    } onCancel: {
      Task { await self.finish(nil) }
    }
  }
  func finish(_ data: Data?) {
    finished = true
    if let waiting {
      self.waiting = nil
      waiting.resume(returning: data)
    } else {
      reply = data
    }
  }
  func write(_ data: Data) {
    guard !finished else { return }
    head.append(data)
    guard head.count <= 65536 else {
      finish(nil)
      return
    }
    guard let end = head.range(of: Data("\r\n\r\n".utf8)) else { return }
    let fields = String(decoding: head[..<end.lowerBound], as: UTF8.self).lowercased().components(
      separatedBy: "\r\n")
    if let reference, fields.first?.hasPrefix("get /reference.png ") == true {
      finish(
        Data(
          "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(reference.count)\r\nConnection: close\r\n\r\n"
            .utf8) + reference)
      return
    }
    if fields.first?.hasPrefix("get /network-redirect ") == true {
      finish(
        Data(
          "HTTP/1.1 302 Found\r\nLocation: http://metrics:6006/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            .utf8))
      return
    }
    let allowed = !requiresLocalhost || fields.contains("host: localhost:\(port)")
    let title = allowed ? (requiresLocalhost ? "Notebooks" : "Run monitor") : "Forbidden"
    let content =
      allowed
      ? (requiresLocalhost ? "Notebook workspace" : Self.dashboard)
      : "Blocking request with non-local Host."
    let html =
      "<meta name=viewport content='width=device-width, initial-scale=1'><meta name=color-scheme content='light dark'><title>\(title)</title><style>body{font:15px system-ui;margin:20px;color:CanvasText;background:Canvas}h2{margin-bottom:0}p{color:GrayText}nav{padding:14px 0;border-bottom:1px solid #8884;margin-bottom:16px}strong{color:#4282c8}svg{display:block;width:100%;height:135px;background:repeating-linear-gradient(0deg,transparent,transparent 32px,#8882 33px)}section{margin:12px 0;border:1px solid #8885;padding:12px;border-radius:10px}small{display:flex;justify-content:space-between;color:GrayText}@media(min-width:580px){body{margin:0}h2{margin:0;padding:18px 24px;background:#202b45;color:white;font-size:17px}nav,main,footer,body>p{margin:12px 24px}main{display:grid;grid-template-columns:1fr 1fr;gap:14px}section{margin:0;padding:16px}svg{height:160px}table{border-collapse:collapse;width:100%}td,th{padding:9px;text-align:left;border-bottom:1px solid #8884}}</style><h2>\(title)</h2>\(content)"
    finish(
      Data(
        "HTTP/1.1 \(allowed ? "200 OK" : "403 Forbidden")\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
          .utf8))
  }
  static let dashboard = """
    <p>poster-study · 0412</p><nav><strong>Scalars</strong>　 Images　 Text</nav>
    <main><section>loss<svg viewBox="0 0 300 140"><path d="M0 10L12 40 20 28 32 55 40 42 56 65 83 75 95 68 110 91 130 82 170 102 190 98 225 112 300 120" fill="none" stroke="#5290db" stroke-width="3"/></svg><small><span>0</span><span>12k</span></small></section>
    <section>learning rate<svg viewBox="0 0 300 140"><path d="M0 120L25 20Q120 32 190 82T300 124" fill="none" stroke="#49a884" stroke-width="3"/></svg><small><span>0</span><span>12k</span></small></section>
    <section>win rate vs full retrieval<svg viewBox="0 0 300 140"><path d="M30 140V60h30v80m35 0V50h30v90m35 0V43h30v97m35 0V78h30v62" fill="#456ddb"/></svg><small>layout · type · palette · none</small></section>
    <section>retrieval hit rate<svg viewBox="0 0 300 140"><path d="M0 110L20 77 42 61 57 53 76 51 99 40 137 37 178 28 210 24 248 22 300 15" fill="none" stroke="#49a884" stroke-width="3"/></svg><small><span>0</span><span>12k</span></small></section></main>
    <footer><p>step 12,400　 epoch 31</p><table><tr><th>Run</th><th>Condition</th><th>Step</th></tr>
    <tr><td>0419-a</td><td>Full retrieval</td><td>12,400</td></tr><tr><td>0419-b</td><td>No layout</td><td>12,400</td></tr><tr><td>0419-c</td><td>No typography</td><td>12,100</td></tr><tr><td>0419-d</td><td>No palette</td><td>11,800</td></tr></table></footer>
    """
}
