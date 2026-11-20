#if os(macOS)
  import AppKit
  import Composition
  import CompositionFixtures
  import Foundation
  import MobileCore
  import Network
  import RelayWebRoutes
  import WebKit

  private struct FixtureStream: RouteStreamOpener {
    let port: UInt16
    var isReconnecting: Bool { false }
    func withRouteStream<R: Sendable>(
      host: String, port: UInt16, _ body: @escaping @Sendable (RouteStream) async throws -> R
    ) async throws -> R {
      guard port == self.port, host == "127.0.0.1" else { throw URLError(.unsupportedURL) }
      let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
      let (events, continuation) = AsyncStream<Bool>.makeStream()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          continuation.yield(true)
          continuation.finish()
        case .failed, .cancelled: continuation.finish()
        default: break
        }
      }
      connection.start(queue: .global())
      defer { connection.cancel() }
      for await _ in events {
        return try await withTaskCancellationHandler {
          try await body(
            RouteStream(
              receive: {
                try await withCheckedThrowingContinuation { done in
                  connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                    data, _, _, error in
                    if let error {
                      done.resume(throwing: error)
                    } else {
                      done.resume(returning: data)
                    }
                  }
                }
              },
              write: { data in
                try await withCheckedThrowingContinuation {
                  (done: CheckedContinuation<Void, Error>) in
                  connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                      if let error { done.resume(throwing: error) } else { done.resume() }
                    })
                }
              },
              finishWriting: {
                connection.send(
                  content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .idempotent)
              }))
        } onCancel: {
          connection.cancel()
        }
      }
      throw URLError(.cannotConnectToHost)
    }
  }

  @MainActor func checkTLS(_ profile: Profile) async throws -> (Bool, Bool) {
    let env = ProcessInfo.processInfo.environment
    guard let port = env["RELAY_TLS_PORT"].flatMap(UInt16.init),
      let rotate = env["RELAY_TLS_ROTATE"]
    else {
      throw NSError(domain: "Missing TLS fixture", code: 1)
    }
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let core = try MobileComposition(
      directory: directory, cache: directory.appending(path: "cache"), keys: DemoKeys())
    await core.runtime.settled()
    guard let prefs = core.runtime.service(Profiles.self) else { throw URLError(.unknown) }
    let pool = WebRoutePool()
    let trust = PrivateServiceTrust(profile: profile, port: port, preferences: prefs)
    let window = QuietWindow(size: NSSize(width: 390, height: 600))
    var results = [false, false]
    for revision in 0...1 {
      if revision == 1 { try Data().write(to: URL(fileURLWithPath: rotate)) }
      let lease = try await pool.open(
        profile: profile, port: port, opener: FixtureStream(port: port))
      let view = lease.makeView()
      window.contentView = view
      let navigation = Navigation()
      var prompted = false
      var changed = false
      navigation.trust = { challenge in
        return await trust.answer(challenge) { _, previous in
          if previous != nil { changed = true } else { prompted = true }
          return previous == nil && revision == 0
        }
      }
      do {
        let url = ServiceAddress(port: port, scheme: "https").url(host: profile.privateName)!
        try await navigation.load(url, in: view)
        let deadline = ContinuousClock.now + .seconds(5)
        while view.title == "Waiting", ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(25))
        }
        results[revision] = revision == 0 && prompted && view.title == "Connected"
        if !results[revision] { print("TLS fixture page: " + (view.title ?? "No title")) }
      } catch {
        results[revision] = revision == 1 && changed
        if !results[revision] { print("TLS navigation: " + error.localizedDescription) }
      }
      window.contentView = nil
      await pool.close(lease)
    }
    await core.runtime.shutdown()
    return (results[0], results[1])
  }
#endif
