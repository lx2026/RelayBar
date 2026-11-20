import Foundation

/// Reserve a stream before opening it. A connected stream releases its open slot
/// immediately, and its stream slot when the scoped relay finishes.
actor ProxyAdmission {
    private struct Waiter {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
        let result: CheckedContinuation<Bool, Never>
    }

    private let limits: ProxyLimits
    private var opening = Set<UUID>()
    private var reserved = Set<UUID>()
    private var queue = [Waiter]()

    init(_ limits: ProxyLimits) { self.limits = limits }

    private var available: Bool {
        opening.count < limits.pendingOpens && reserved.count < limits.streams
    }

    private func reserve(_ id: UUID) {
        reserved.insert(id)
        opening.insert(id)
    }

    func acquire(_ id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if available {
            reserve(id)
            return true
        }
        guard queue.count < limits.queuedOpens else { return false }
        let deadline = ContinuousClock.now + limits.queueTimeout
        return await withTaskCancellationHandler {
            await withCheckedContinuation { result in
                let timer = Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    withdraw(id)
                }
                queue.append(Waiter(id: id, deadline: deadline, timer: timer, result: result))
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    private func withdraw(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiter.timer.cancel()
        waiter.result.resume(returning: false)
    }

    func connected(_ id: UUID) {
        opening.remove(id)
        admitWaiting()
    }

    func finished(_ id: UUID) {
        opening.remove(id)
        reserved.remove(id)
        admitWaiting()
    }

    private func admitWaiting() {
        while available && !queue.isEmpty {
            let waiter = queue.removeFirst()
            waiter.timer.cancel()
            let admitted = ContinuousClock.now < waiter.deadline
            if admitted { reserve(waiter.id) }
            waiter.result.resume(returning: admitted)
        }
    }
}
