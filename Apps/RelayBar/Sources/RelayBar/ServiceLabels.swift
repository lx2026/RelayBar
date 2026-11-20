import PreviewSupport
import Combine
import Composition
import Foundation
import os

/// What answered on one forwarded web port.
struct ServiceLabel: Equatable, Sendable {
    var name: String?
    var isResponding: Bool

    /// The words the tunnel list shows after the host.
    var caption: String {
        guard isResponding else { return "no response" }
        return name ?? "responding"
    }
}

/// The current labels, keyed by rule id. Website Labels fills it; the tunnel list reads it through a port.
@MainActor
final class ServiceLabelBoard: ObservableObject {
    @Published private(set) var labels: [UUID: ServiceLabel] = [:]

    func record(_ label: ServiceLabel, for rule: UUID) {
        guard labels[rule] != label else { return }
        labels[rule] = label
    }

    func clear(_ rules: [UUID]) {
        let remaining = labels.filter { !rules.contains($0.key) }
        guard remaining.count != labels.count else { return }
        labels = remaining
    }
}

/// Asks one local URL what is serving it.
protocol ServiceProbing: Sendable {
    func probe(_ url: URL) async -> ServiceLabel
}

// MARK: - Recognition

extension ServiceLabel {
    static func recognizing(status: Int, headers: [String: String], body: Data) -> ServiceLabel {
        ServiceLabel(name: WebsiteName.recognizing(status: status, contentType: headers["content-type"], body: body),
                     isResponding: true)
    }
}

// MARK: - Probe

/// The production probe: one plain HTTP GET to a loopback URL with no cookies, credentials or cache,
/// three seconds at most, no more than 64 KiB read, and redirects followed only to the same host and port.
struct HTTPServiceProbe: ServiceProbing {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
    static let byteLimit = WebsiteName.byteLimit
    static let timeout: TimeInterval = 3
    static let redirectLimit = 3

    func probe(_ url: URL) async -> ServiceLabel {
        guard let fetched = await fetch(url) else {
            return ServiceLabel(name: nil, isResponding: false)
        }
        var headers: [String: String] = [:]
        for (name, value) in fetched.response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }
        return ServiceLabel.recognizing(status: fetched.response.statusCode, headers: headers, body: fetched.body)
    }

    /// The response and at most `byteLimit` bytes of its body; nil when the URL is refused or nothing answered.
    /// The session is invalidated and its teardown awaited before this returns.
    func fetch(_ url: URL) async -> (response: HTTPURLResponse, body: Data)? {
        guard let request = Self.request(for: url), let target = request.url else { return nil }
        let delegate = ProbeSessionDelegate(origin: target)
        let session = URLSession(configuration: Self.configuration(), delegate: delegate, delegateQueue: nil)
        let result = await exchange(request, session: session, delegate: delegate)
        session.invalidateAndCancel()
        await delegate.invalidated()
        return result
    }

    private func exchange(_ request: URLRequest, session: URLSession,
                          delegate: ProbeSessionDelegate) async -> (response: HTTPURLResponse, body: Data)? {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            // A server that asked for credentials answered, even though it was given none.
            guard let asking = delegate.challengeResponse else { return nil }
            return (asking, Data())
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count == Self.byteLimit {
                    break
                }
            }
        } catch {
            // A body cut short still came from a server that answered.
        }
        bytes.task.cancel()
        return (http, body)
    }

    /// The one request a probe may send to `url`, or nil when the URL is not plain HTTP to loopback.
    /// It carries no user information from the URL, no cookies, and fixed headers that say nothing
    /// about this Mac, its language or this app's version. Redirects are rebuilt through this too.
    static func request(for url: URL) -> URLRequest? {
        guard isLoopback(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        guard let target = components.url else { return nil }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        for (name, value) in fixedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Sent with every probe in place of the system's defaults, which name the app, its version and
    /// the person's languages.
    static let fixedHeaders = [
        "User-Agent": "Mozilla/5.0",
        "Accept": "text/html,*/*;q=0.8",
        "Accept-Language": "en"
    ]

    /// True for a plain HTTP URL whose host is 127.0.0.1, localhost or ::1. HTTPS is refused: evaluating
    /// a certificate can fetch from addresses the certificate names, and Open Website only uses HTTP.
    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    /// True when both URLs name the same host and the same port.
    static func isSameHostAndPort(_ url: URL, as origin: URL) -> Bool {
        let sameHost = url.host(percentEncoded: false)?.lowercased() == origin.host(percentEncoded: false)?.lowercased()
        return sameHost && port(of: url) == port(of: origin)
    }

    /// An ephemeral session that keeps and sends nothing: no cookies, no credentials, no cache.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        // A loopback request must never be handed to a configured proxy.
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    private static func port(of url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

/// Keeps one probe on its origin: a redirect is followed only as a new plain HTTP request to the same
/// host and port, at most three times, and no authentication or trust challenge is answered.
private final class ProbeSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: URL
    private let redirects = OSAllocatedUnfairLock(initialState: 0)
    private let refused = OSAllocatedUnfairLock<HTTPURLResponse?>(initialState: nil)
    private struct Teardown {
        var isInvalid = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let teardown = OSAllocatedUnfairLock(initialState: Teardown())

    init(origin: URL) {
        self.origin = origin
    }

    /// The response that asked for credentials, when the probe refused to give any.
    var challengeResponse: HTTPURLResponse? { refused.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let count = redirects.withLock { followed in
            followed += 1
            return followed
        }
        guard
            count <= HTTPServiceProbe.redirectLimit,
            let next = request.url,
            HTTPServiceProbe.isSameHostAndPort(next, as: origin),
            let rebuilt = HTTPServiceProbe.request(for: next)
        else {
            // The redirect response itself ends the probe; it still counts as an answer.
            completionHandler(nil)
            return
        }
        // Never the request the server proposed: the probe's own request to the new address.
        completionHandler(rebuilt)
    }

    // The async form of the challenge callback: the completion-handler form's signature differs between SDK
    // versions, and a form that does not match exactly is silently never called.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // No challenge is answered. Going on without a credential would send the request again, so the
        // probe stops here and keeps the response that asked. The probe never speaks TLS, so a trust
        // challenge is refused as well and no certificate is evaluated.
        if challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust {
            let asking = challenge.failureResponse as? HTTPURLResponse
            refused.withLock { $0 = asking }
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let waiter = teardown.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isInvalid = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Returns once the session has finished invalidating, so a probe leaves nothing running behind it.
    func invalidated() async {
        await withCheckedContinuation { continuation in
            let isInvalid = teardown.withLock { state -> Bool in
                if !state.isInvalid {
                    state.waiter = continuation
                }
                return state.isInvalid
            }
            if isInvalid {
                continuation.resume()
            }
        }
    }
}

// MARK: - Feature

/// Website Labels. While a profile runs, each of its rules that opens in a browser is asked what it
/// serves, once when the profile starts running and then every `interval`. A profile's labels go when
/// it stops running.
struct ServiceLabelsFeature: Feature {
    var interval: Duration = .seconds(30)
    @Constant var probe: any ServiceProbing
    @Need(RelayServices.Tunnels.self) var tunnels
    @Offer(RelayServices.ServiceLabels.self) var labels

    func run(_ context: FeatureContext) async throws {
        let board = ServiceLabelBoard()
        let schedule = ServiceProbeSchedule(board: board, probe: probe, interval: interval, context: context)
        let observation = tunnels.$phases.combineLatest(tunnels.$tunnels).sink { phases, profiles in
            schedule.follow(phases: phases, profiles: profiles)
        }
        try context.effect("website label observation", cancel: { observation.cancel() }) {}
        labels.set(board)
    }
}

/// Website Labels' working state: one probing task per running profile, owned by the feature's context,
/// and a gate that lets at most four probes run at once.
@MainActor
private final class ServiceProbeSchedule {
    private static let concurrentProbes = 4
    private let board: ServiceLabelBoard
    private let probe: any ServiceProbing
    private let interval: Duration
    private weak var context: FeatureContext?
    private var watching: [UUID: (task: Task<Void, Never>, rules: [UUID], urls: [URL])] = [:]
    private var probing = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(board: ServiceLabelBoard, probe: any ServiceProbing, interval: Duration, context: FeatureContext) {
        self.board = board
        self.probe = probe
        self.interval = interval
        self.context = context
    }

    /// Stops watching profiles that are no longer running, dropping their labels, and starts watching
    /// profiles that now run.
    func follow(phases: [UUID: TunnelPhase], profiles: [Tunnel]) {
        let running = profiles.filter { phases[$0.id] == .running }
        let runningIDs = Set(running.map(\.id))
        for (id, entry) in watching where !runningIDs.contains(id) {
            entry.task.cancel()
            watching[id] = nil
            board.clear(entry.rules)
        }
        guard let context, context.isActive else { return }
        for profile in running {
            // A rule bound to another address is not asked, so it never shows "no response" for a refusal.
            let targets = profile.rules.compactMap { rule -> (rule: UUID, url: URL)? in
                guard let url = rule.localBrowserURL, HTTPServiceProbe.isLoopback(url) else { return nil }
                return (rule.id, url)
            }
            if let entry = watching[profile.id] {
                guard entry.urls != targets.map(\.url) else { continue }
                entry.task.cancel()
                watching[profile.id] = nil
                board.clear(entry.rules)
            }
            guard !targets.isEmpty else { continue }
            let task = try? context.task("website labels for profile \(profile.id)") { [weak self] in
                await self?.watch(targets)
            }
            guard let task else { continue }
            watching[profile.id] = (task, targets.map(\.rule), targets.map(\.url))
        }
    }

    private func watch(_ targets: [(rule: UUID, url: URL)]) async {
        while !Task.isCancelled {
            for target in targets {
                await admit()
                defer { release() }
                guard let context else { return }
                let probe = probe
                // A result that arrives after the profile stopped or the feature was withdrawn is dropped.
                guard let label = try? await context.perform("service probe", { await probe.probe(target.url) }) else {
                    return
                }
                // A probe cut short by its profile stopping reports no response; that is not a finding.
                guard !Task.isCancelled else { return }
                board.record(label, for: target.rule)
            }
            try? await Task.sleep(for: interval)
        }
    }

    private func admit() async {
        if probing < Self.concurrentProbes {
            probing += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the finished probe's place to the next waiting one, if any.
    private func release() {
        guard waiting.isEmpty else {
            waiting.removeFirst().resume()
            return
        }
        probing -= 1
    }
}
