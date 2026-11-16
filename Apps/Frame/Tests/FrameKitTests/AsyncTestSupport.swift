import XCTest

/// A latch that fixture work enters and the test releases, one per key. Entry is remembered, a release
/// that arrives before the wait lets it pass, and `releaseAll` opens every key for good.
actor KeyedGate {
    static let defaultKey = "default"
    private let failure: String
    private let timeout: any Error
    private var entered: Set<String> = []
    private var open: Set<String> = []
    private var allOpen = false
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// `failure` is reported and `timeout` thrown when nothing enters within five seconds.
    init(failure: String, timeout: any Error) {
        self.failure = failure
        self.timeout = timeout
    }
    func wait(_ key: String = KeyedGate.defaultKey) async {
        entered.insert(key)
        if !allOpen, !open.contains(key) { await withCheckedContinuation { waiting[key, default: []].append($0) } }
    }
    func release(_ key: String = KeyedGate.defaultKey) {
        open.insert(key)
        for continuation in waiting.removeValue(forKey: key) ?? [] { continuation.resume() }
    }
    func releaseAll() {
        allOpen = true
        for key in Array(waiting.keys) { release(key) }
    }
    func waitFor(_ key: String = KeyedGate.defaultKey) async throws {
        for _ in 0..<500 {
            if entered.contains(key) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(failure)
        throw timeout
    }
}
