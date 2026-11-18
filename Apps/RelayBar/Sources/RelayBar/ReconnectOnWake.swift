import AppKit
import Composition
import Network
import os

/// Tells Reconnect on Wake that the Mac woke or the network came back.
protocol RecoveryEvents: Sendable {
    /// Delivers one value per wake or network return until the consumer stops iterating.
    func events() -> AsyncStream<Void>
}

/// The system's events: `NSWorkspace.didWakeNotification`, and a network path that becomes satisfied
/// after it was not. The path monitor's first report is not an event. Ending the stream removes the
/// observer and cancels the monitor.
struct SystemRecoveryEvents: RecoveryEvents {
    func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            // A notification token can be removed from any thread.
            nonisolated(unsafe) let observer = center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield()
            }
            let wasSatisfied = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                let isSatisfied = path.status == .satisfied
                let networkReturned = wasSatisfied.withLock { previous in
                    let returned = previous == false && isSatisfied
                    previous = isSatisfied
                    return returned
                }
                if networkReturned {
                    continuation.yield()
                }
            }
            monitor.start(queue: DispatchQueue(label: "RelayBar.recovery-path"))
            continuation.onTermination = { _ in
                center.removeObserver(observer)
                monitor.cancel()
            }
        }
    }
}

/// Reconnect on Wake. A wake or a returning network makes every waiting retry now instead of at the end
/// of its backoff. Events are debounced, so a wake followed by a network change causes one retry.
struct RecoveryFeature: Feature {
    var debounce: Duration = .seconds(2)
    @Constant var events: any RecoveryEvents
    @Need(RelayServices.Tunnels.self) var tunnels

    func run(_ context: FeatureContext) async throws {
        let store = tunnels
        let source = events
        let debounce = debounce
        try context.task("wake and network events") { [weak context] in
            var wait: Task<Void, Never>?
            for await _ in source.events() {
                wait?.cancel()
                wait = try? context?.task("retry debounce") { [weak context] in
                    do {
                        try await Task.sleep(for: debounce)
                    } catch {
                        return
                    }
                    guard context?.isActive == true else { return }
                    store.retryWaitingNow()
                }
            }
        }
    }
}
