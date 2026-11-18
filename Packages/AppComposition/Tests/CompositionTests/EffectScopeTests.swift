import Composition
import Foundation
import XCTest

@MainActor
final class EffectScopeTests: XCTestCase {
    func testDisposalCancelsAllTasksBeforeWaitingForADependentTask() async throws {
        let scope = EffectScope()
        var finished = 0
        let first = try scope.task {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            finished += 1
        }
        _ = try scope.task { await first.value; finished += 1 }
        await Task.yield()
        let start = ContinuousClock.now
        await scope.dispose()
        XCTAssertEqual(finished, 2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(scope.count, 0)
    }

    func testObserverRejectsEventsImmediatelyOnInvalidation() async throws {
        let scope = EffectScope(), center = NotificationCenter(), name = Notification.Name(UUID().uuidString)
        let calls = LockedCalls()
        try scope.observe(center, name: name) { _ in calls.increment() }
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.value, 1)
        scope.invalidate()
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.value, 1)
        await scope.dispose()
    }

    func testInvalidationClosesAdmissionBeforeAsynchronousDisposal() async throws {
        let scope = EffectScope()
        var disposed = false, ran = false
        try scope.own { disposed = true }
        scope.invalidate()
        XCTAssertThrowsError(try scope.task { ran = true })
        do { _ = try await scope.run { ran = true }; XCTFail("Retiring scope accepted work") } catch {}
        XCTAssertFalse(ran)
        XCTAssertFalse(disposed)
        await scope.dispose()
        XCTAssertTrue(disposed)
    }

    func testDisposeJoinsExplicitReleaseBeforeDisposingDependencies() async throws {
        let scope = EffectScope()
        var continueRelease: CheckedContinuation<Void, Never>?
        var order: [String] = []
        try scope.own { order.append("dependency") }
        let id = try scope.own {
            order.append("releasing")
            await withCheckedContinuation { continueRelease = $0 }
            order.append("released")
        }
        let releasing = Task { await scope.release(id) }
        while continueRelease == nil { await Task.yield() }
        let disposal = Task { await scope.dispose() }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(order, ["releasing"])
        XCTAssertEqual(scope.count, 2)
        continueRelease?.resume()
        await disposal.value; await releasing.value
        XCTAssertEqual(order, ["releasing", "released", "dependency"])
        XCTAssertEqual(scope.count, 0)
        XCTAssertTrue(scope.isDisposed)
    }

    func testScopeWaitsForCancellationAndDisposesOnce() async throws {
        let scope = EffectScope()
        var started = false, cancelled = false, undos = 0
        try scope.own { undos += 1 }
        try scope.task {
            started = true
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelled = true }
        }
        while !started { await Task.yield() }
        async let first: Void = scope.dispose()
        async let second: Void = scope.dispose()
        _ = await (first, second)
        XCTAssertTrue(cancelled); XCTAssertEqual(undos, 1); XCTAssertEqual(scope.count, 0)
        XCTAssertThrowsError(try scope.own {})
    }

    func testDisposalNamesTheStepItIsWaitingOn() async throws {
        let scope = EffectScope()
        var release: CheckedContinuation<Void, Never>?
        try scope.own("ssh master exit") { await withCheckedContinuation { release = $0 } }
        let disposal = Task { await scope.dispose() }
        while release == nil { await Task.yield() }
        XCTAssertEqual(scope.waitingOn, "ssh master exit")
        XCTAssertFalse(scope.isOpen)
        release?.resume()
        await disposal.value
        XCTAssertNil(scope.waitingOn)
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
