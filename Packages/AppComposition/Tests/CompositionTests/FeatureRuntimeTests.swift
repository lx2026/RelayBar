import Composition
import Foundation
import XCTest

@MainActor
final class FeatureRuntimeTests: XCTestCase {
    private func phase(_ runtime: FeatureRuntime, _ id: String) -> FeaturePhase? { runtime.status(id)?.phase }

    // MARK: The audit's probes

    func testUnrelatedFeatureDoesNotWaitOnSlowCleanup() async throws {
        let log = Log(), runtime = FeatureRuntime()
        try runtime.set { FeatureNode("slow") { Probe(name: "slow", cleanupGate: "slow", log: log) } }
        await runtime.settled()
        try runtime.set { FeatureNode("fast") { Probe(name: "fast", log: log) } }
        try await until("fast to load beside the cleanup") { self.phase(runtime, "fast") == .active }
        XCTAssertEqual(phase(runtime, "slow"), .unloading)
        log.open("slow")
        await runtime.settled()
        XCTAssertNil(runtime.status("slow"))
    }

    func testUnrelatedFeatureDoesNotWaitOnSlowLoad() async throws {
        let log = Log(), runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("connect") { Probe(name: "connect", loadGate: "connect", log: log) }
            FeatureNode("toggle") { Probe(name: "toggle", log: log) }
        }
        try await until("toggle to load beside the slow load") { self.phase(runtime, "toggle") == .active }
        XCTAssertEqual(phase(runtime, "connect"), .loading)
        log.open("connect")
        await runtime.settled()
        XCTAssertEqual(phase(runtime, "connect"), .active)
    }

    func testIndependentCleanupsOverlap() async throws {
        let log = Log(), runtime = FeatureRuntime()
        let ids = (0..<5).map { "p\($0)" }
        try runtime.set { for id in ids { FeatureNode(id) { Probe(name: id, cleanupGate: "release", log: log) } } }
        await runtime.settled()
        try runtime.set([])
        try await until("every cleanup to be in flight at once") {
            ids.allSatisfy { log.events.contains("unloading \($0)") }
        }
        XCTAssertFalse(log.events.contains { $0.hasPrefix("unloaded") })
        log.open("release")
        await runtime.settled()
        XCTAssertTrue(runtime.statuses.isEmpty)
    }

    func testCleanupThatNeverReturnsIsNamedContainedAndCannotBlockShutdown() async throws {
        let log = Log(), runtime = FeatureRuntime(deadline: .milliseconds(80))
        try runtime.set { FeatureNode("hung") { Probe(name: "hung", cleanupGate: "never", log: log) } }
        await runtime.settled()
        try runtime.set { FeatureNode("other") { Probe(name: "other", log: log) } }
        try await until("the unrelated feature") { self.phase(runtime, "other") == .active }
        try await until("the stuck report") { if case .stuck = self.phase(runtime, "hung") { return true }; return false }
        guard case .stuck(let reason) = phase(runtime, "hung") else { return XCTFail("Not reported") }
        XCTAssertTrue(reason.contains("hung cleanup"), reason)
        XCTAssertTrue(runtime.diagnostics.contains { $0.contains("hung") && $0.contains("hung cleanup") })

        let start = ContinuousClock.now
        let unfinished = await runtime.shutdown(deadline: .milliseconds(500))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(unfinished.map(\.id), ["hung"])
        XCTAssertNil(runtime.status("other"))

        log.open("never")
        try await until("the late cleanup") { runtime.status("hung") == nil }
        XCTAssertTrue(runtime.diagnostics.contains { $0.contains("late cleanup finished") })
    }

    func testStuckDependentStopsHoldingItsProvider() async throws {
        let log = Log(), wire = Wire(), runtime = FeatureRuntime(deadline: .milliseconds(80))
        try runtime.set {
            FeatureNode("provider") { Provider(log: log, wire: wire) }
            FeatureNode("parent") { Probe(name: "parent", log: log) } children: {
                FeatureNode("child") { Probe(name: "child", cleanupGate: "never", log: log) }
            }
        }
        await runtime.settled()
        try runtime.set { FeatureNode("provider") { Provider(log: log, wire: wire) } }
        try await until("the parent to unload after its child is reported") { log.events.contains("unloaded parent") }
        if case .stuck = phase(runtime, "parent/child") {} else { XCTFail("Child was not reported") }
        log.open("never")
        await runtime.shutdown()
    }

    func testFailureIsRetriedOnlyWhenItsInputsChangeOrOnRequest() async throws {
        struct Flaky: Feature {
            var revision = 0
            @Constant var log: Log
            @MainActor func run(_ context: FeatureContext) async throws {
                log.counts["flaky", default: 0] += 1
                if log.count("fail") > 0 { log.counts["fail"]! -= 1; throw CompositionError("fixture failed") }
            }
        }
        let log = Log(), runtime = FeatureRuntime()
        log.counts["fail"] = 2
        try runtime.set { FeatureNode("flaky") { Flaky(log: log) } }
        await runtime.settled()
        XCTAssertEqual(phase(runtime, "flaky"), .failed("fixture failed"))
        try runtime.set { FeatureNode("flaky") { Flaky(log: log) } }
        await runtime.settled()
        XCTAssertEqual(log.count("flaky"), 1, "An identical tree must not retry")

        runtime.retry("flaky")
        await runtime.settled()
        XCTAssertEqual(log.count("flaky"), 2)
        XCTAssertEqual(phase(runtime, "flaky"), .failed("fixture failed"))

        try runtime.set { FeatureNode("flaky") { Flaky(revision: 1, log: log) } }
        await runtime.settled()
        XCTAssertEqual(log.count("flaky"), 3)
        XCTAssertEqual(phase(runtime, "flaky"), .active)
        await runtime.shutdown()
    }

    func testFailureIsRetriedWhenADependencyIsReplaced() async throws {
        struct Picky: Feature {
            @Constant var log: Log
            @Need(Connection.self) var connection
            @MainActor func run(_ context: FeatureContext) async throws {
                log.counts["picky", default: 0] += 1
                if connection.value == 0 { throw CompositionError("connection not ready") }
            }
        }
        let log = Log(), wire = Wire(), runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("provider") { Provider(log: log, wire: wire) }
            FeatureNode("picky") { Picky(log: log) }
        }
        await runtime.settled()
        XCTAssertEqual(phase(runtime, "picky"), .failed("connection not ready"))
        let ready = Counter(); ready.value = 1
        wire.slot?.set(ready)
        await runtime.settled()
        XCTAssertEqual(phase(runtime, "picky"), .active)
        XCTAssertEqual(log.count("picky"), 2)
        await runtime.shutdown()
    }

    func testRapidChangesCoalesceToTheLatestTree() async throws {
        let log = Log(), runtime = FeatureRuntime()
        for index in 0..<20 {
            try runtime.set(index % 2 == 0 ? [FeatureNode("feature") { Probe(name: "feature", log: log) }] : [])
        }
        await runtime.settled()
        XCTAssertEqual(log.count("feature"), 0)
        for index in 0..<21 {
            try runtime.set(index % 2 == 0 ? [FeatureNode("feature") { Probe(name: "feature", log: log) }] : [])
        }
        await runtime.settled()
        XCTAssertEqual(log.count("feature"), 1)
        XCTAssertEqual(phase(runtime, "feature"), .active)
        await runtime.shutdown()
    }

    func testOnlyDeclaredServicesAreReachableAndMissingOnesAreExplained() async throws {
        let log = Log(), wire = Wire(), captured = Captured(), runtime = FeatureRuntime()
        try runtime.set { FeatureNode("consumer") { Consumer(log: log, captured: captured) } }
        await runtime.settled()
        XCTAssertEqual(phase(runtime, "consumer"), .pending("Needs Connection which no feature offers"))
        try runtime.set {
            FeatureNode("consumer") { Consumer(log: log, captured: captured) }
            FeatureNode("provider") { Provider(offersAtLoad: false, log: log, wire: wire) }
        }
        await runtime.settled()
        XCTAssertEqual(phase(runtime, "consumer"), .pending("Needs Connection from provider"))
        XCTAssertEqual(runtime.unavailable.map(\.id), ["consumer"])
        await runtime.shutdown()
    }

    // MARK: Ordering and ownership

    func testResourceCancellationUnblocksOwnedJobBeforeAwaitedCleanup() async throws {
        struct Resource: Feature {
            @Constant var log: Log
            @MainActor func run(_ context: FeatureContext) async throws {
                let log = log
                try context.effect("resource", cancel: { log.events.append("cancel-resource"); log.open("job") }) {
                    XCTAssertTrue(log.events.contains("job-finished"))
                    log.events.append("dispose-resource")
                }
                try context.task("job") {
                    await log.wait("job")
                    log.events.append("job-finished")
                }
            }
        }
        let log = Log(), runtime = FeatureRuntime()
        try runtime.set { FeatureNode("resource") { Resource(log: log) } }
        await runtime.settled()
        await runtime.shutdown()
        XCTAssertEqual(log.events, ["cancel-resource", "job-finished", "dispose-resource"])
        await runtime.shutdown()
        XCTAssertEqual(log.events.count, 3)
    }

    func testOwnedWorkCanRemoveItsOwnFeatureWithoutDeadlock() async throws {
        struct SelfRemoving: Feature {
            @Constant var log: Log
            @Constant var runtime: FeatureRuntime
            @MainActor func run(_ context: FeatureContext) async throws {
                let log = log, runtime = runtime
                try context.effect("fixture") { log.events.append("released") }
                try context.task("remove myself") {
                    await log.wait("go")
                    try? runtime.set([])
                }
            }
        }
        let log = Log(), runtime = FeatureRuntime()
        try runtime.set { FeatureNode("fixture") { SelfRemoving(log: log, runtime: runtime) } }
        await runtime.settled()
        log.open("go")
        try await until("the feature to remove itself") { runtime.statuses.isEmpty }
        XCTAssertEqual(log.events, ["released"])
    }

    func testWithdrawalDrainsConsumerBeforeProviderAndRejectsLateWork() async throws {
        let log = Log(), wire = Wire(), captured = Captured(), runtime = FeatureRuntime()
        let consumer = FeatureNode("consumer") { Consumer(log: log, captured: captured) }
        try runtime.set([consumer])
        await runtime.settled()
        XCTAssertNil(captured.context)
        try runtime.set([consumer, FeatureNode("provider") { Provider(log: log, wire: wire) }])
        await runtime.settled()
        let context = try XCTUnwrap(captured.context)
        XCTAssertTrue(context.isActive)
        try runtime.set([consumer])
        // Withdrawal is synchronous with the next pass; cleanup follows.
        await runtime.settled()
        XCTAssertEqual(log.events, ["unloaded consumer with 0", "unloaded provider"])
        XCTAssertThrowsError(try context.checkActive())
        XCTAssertThrowsError(try context.task {})
        XCTAssertEqual(phase(runtime, "consumer"), .pending("Needs Connection which no feature offers"))
        await runtime.shutdown()
        XCTAssertEqual(log.events.count, 2)
    }

    func testFailedLoadRollsBackAndNeverPublishesItsOffers() async throws {
        struct Broken: Feature {
            @Constant var log: Log
            @Offer(Connection.self) var connection
            @MainActor func run(_ context: FeatureContext) async throws {
                log.counts["resources", default: 0] += 1
                let log = log
                try context.effect("resource") { log.counts["resources"]! -= 1 }
                connection.set(Counter())
                throw CompositionError("fixture failed")
            }
        }
        let log = Log(), captured = Captured(), runtime = FeatureRuntime()
        let port = runtime.port(Connection.self)
        try runtime.set {
            FeatureNode("broken") { Broken(log: log) }
            FeatureNode("consumer") { Consumer(log: log, captured: captured) }
        }
        await runtime.settled()
        XCTAssertEqual(log.count("resources"), 0)
        XCTAssertEqual(log.count("consumer"), 0)
        XCTAssertNil(port.value)
        XCTAssertEqual(phase(runtime, "broken"), .failed("fixture failed"))
        await runtime.shutdown()
    }

    func testReplacingAnOfferReloadsConsumersButMutatingItDoesNot() async throws {
        let log = Log(), wire = Wire(), captured = Captured(), runtime = FeatureRuntime()
        let tree = [FeatureNode("provider") { Provider(log: log, wire: wire) },
                    FeatureNode("consumer") { Consumer(log: log, captured: captured) }]
        try runtime.set(tree)
        await runtime.settled()
        let first = try XCTUnwrap(runtime.status("consumer")?.generation)
        captured.counter?.value = 3
        try runtime.set(tree)
        await runtime.settled()
        XCTAssertEqual(log.count("consumer"), 1)

        let replacement = Counter(); replacement.value = 9
        wire.slot?.set(replacement)
        await runtime.settled()
        XCTAssertEqual(log.count("consumer"), 2)
        XCTAssertEqual(log.count("provider"), 1, "The provider itself keeps running")
        XCTAssertTrue(captured.counter === replacement)
        XCTAssertEqual(log.events, ["unloaded consumer with 3"])
        XCTAssertGreaterThan(try XCTUnwrap(runtime.status("consumer")?.generation), first)
        await runtime.shutdown()
    }

    func testSlotFillsAndClearsWhileActiveAndThePortFollows() async throws {
        let log = Log(), wire = Wire(), captured = Captured(), runtime = FeatureRuntime()
        let port = runtime.port(Connection.self)
        try runtime.set {
            FeatureNode("provider") { Provider(offersAtLoad: false, log: log, wire: wire) }
            FeatureNode("consumer") { Consumer(log: log, captured: captured) }
        }
        await runtime.settled()
        XCTAssertNil(port.value)
        XCTAssertEqual(log.count("consumer"), 0)

        let one = Counter(); one.value = 1
        wire.slot?.set(one)
        await runtime.settled()
        XCTAssertTrue(port.value === one)
        XCTAssertTrue(runtime.service(Connection.self) === one)
        XCTAssertEqual(phase(runtime, "consumer"), .active)

        wire.slot?.clear()
        // Withdrawal is synchronous: consumers and ports see it before any cleanup has run.
        XCTAssertFalse(try XCTUnwrap(captured.context).isActive)
        XCTAssertNil(port.value)
        XCTAssertTrue(log.events.isEmpty)
        await runtime.settled()
        XCTAssertEqual(log.events, ["unloaded consumer with 1"])

        let two = Counter(); two.value = 2
        wire.slot?.set(two)
        await runtime.settled()
        XCTAssertTrue(port.value === two)
        XCTAssertEqual(log.count("consumer"), 2)
        XCTAssertEqual(log.count("provider"), 1)
        await runtime.shutdown()
        XCTAssertNil(port.value)
    }

    func testOwnerCanWaitUntilNothingHoldsAWithdrawnValue() async throws {
        struct SlowConsumer: Feature {
            @Constant var log: Log
            @Need(Connection.self) var connection
            @MainActor func run(_ context: FeatureContext) async throws {
                let log = log
                try context.effect("slow consumer") { await log.wait("consumer"); log.events.append("consumer released") }
            }
        }
        let log = Log(), wire = Wire(), runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("provider") { Provider(log: log, wire: wire) }
            FeatureNode("consumer") { SlowConsumer(log: log) }
        }
        await runtime.settled()
        let slot = try XCTUnwrap(wire.slot)
        slot.clear()
        let release = Task { await slot.drained(); log.events.append("provider released") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(log.events.isEmpty, "The old value is still held by a consumer that is cleaning up")
        log.open("consumer")
        await release.value
        XCTAssertEqual(log.events, ["consumer released", "provider released"])
        await slot.drained()
        await runtime.shutdown()
    }

    func testAStaleSlotFromAnEarlierLoadCannotPublish() async throws {
        let log = Log(), wire = Wire(), runtime = FeatureRuntime()
        let port = runtime.port(Connection.self)
        try runtime.set { FeatureNode("provider") { Provider(offersAtLoad: false, log: log, wire: wire) } }
        await runtime.settled()
        let stale = try XCTUnwrap(wire.slot)
        try runtime.set { FeatureNode("provider") { Provider(value: 1, offersAtLoad: false, log: log, wire: wire) } }
        await runtime.settled()
        XCTAssertEqual(log.count("provider"), 2)
        stale.set(Counter())
        await runtime.settled()
        XCTAssertNil(port.value)
        await runtime.shutdown()
    }

    func testPerformRejectsAResultThatArrivesAfterWithdrawal() async throws {
        let log = Log(), wire = Wire(), captured = Captured(), runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("provider") { Provider(log: log, wire: wire) }
            FeatureNode("consumer") { Consumer(log: log, captured: captured) }
        }
        await runtime.settled()
        let context = try XCTUnwrap(captured.context)
        let call = Task { try await context.perform("listing") { await log.wait("reply"); return 42 } }
        try await until("the call to be owned") { context.effects.count == 2 }
        wire.slot?.clear()
        log.open("reply")
        do { _ = try await call.value; XCTFail("A late result was returned") } catch {}
        await runtime.settled()
        do { _ = try await context.perform { 1 }; XCTFail("A retired context accepted work") } catch {}
        await runtime.shutdown()
    }

    func testRealmsGiveEachSubtreeItsOwnService() async throws {
        let log = Log(), runtime = FeatureRuntime()
        let left = Captured(), right = Captured()
        try runtime.set {
            for (id, value, captured) in [("left", 1, left), ("right", 2, right)] {
                FeatureNode.realm(id, isolating: [Connection.self]) {
                    FeatureNode("provider") { Provider(value: value, log: log, wire: Wire()) }
                    FeatureNode("consumer") { Consumer(name: id, log: log, captured: captured) }
                }
            }
        }
        await runtime.settled()
        XCTAssertEqual(left.counter?.value, 1)
        XCTAssertEqual(right.counter?.value, 2)
        XCTAssertEqual(runtime.service(Connection.self, realm: "left")?.value, 1)
        XCTAssertEqual(runtime.port(Connection.self, realm: "right").value?.value, 2)
        XCTAssertNil(runtime.service(Connection.self))
        await runtime.shutdown()
    }

    func testChangingConfigurationReloadsOnlyThatFeature() async throws {
        let log = Log(), runtime = FeatureRuntime()
        func tree(_ revision: Int) -> [FeatureNode] {
            [FeatureNode("a") { Probe(name: "a", revision: revision, log: log) },
             FeatureNode("b") { Probe(name: "b", log: log) }]
        }
        try runtime.set(tree(0))
        await runtime.settled()
        try runtime.set(tree(0))
        await runtime.settled()
        XCTAssertEqual(log.count("a"), 1)
        try runtime.set(tree(1))
        await runtime.settled()
        XCTAssertEqual(log.count("a"), 2)
        XCTAssertEqual(log.count("b"), 1)
        XCTAssertEqual(runtime.status("b")?.generation, 1)
        await runtime.shutdown()
    }

    func testChildrenLoadAfterTheirParentAndUnloadBeforeIt() async throws {
        let log = Log(), runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("parent") { Probe(name: "parent", loadGate: "parent", log: log) } children: {
                FeatureNode("child") { Probe(name: "child", log: log) }
            }
        }
        try await until("the parent to start") { log.events.contains("loading parent") }
        XCTAssertEqual(phase(runtime, "parent/child"), .pending("Waiting for parent"))
        log.open("parent")
        await runtime.settled()
        XCTAssertEqual(phase(runtime, "parent/child"), .active)
        await runtime.shutdown()
        XCTAssertEqual(Array(log.events.suffix(4)), ["unloading child", "unloaded child", "unloading parent", "unloaded parent"])
    }

    func testRemovalDuringASlowLoadFinishesTheLoadThenCleansUp() async throws {
        let log = Log(), runtime = FeatureRuntime()
        try runtime.set { FeatureNode("slow") { Probe(name: "slow", loadGate: "slow", log: log) } }
        try await until("the load to start") { log.events.contains("loading slow") }
        try runtime.set([])
        await Task.yield(); await Task.yield()
        XCTAssertEqual(log.events, ["loading slow"])
        XCTAssertEqual(phase(runtime, "slow"), .loading)
        log.open("slow")
        await runtime.settled()
        XCTAssertEqual(log.events, ["loading slow", "loaded slow", "unloading slow", "unloaded slow"])
        XCTAssertTrue(runtime.statuses.isEmpty)
    }

    func testInvalidTreeIsRejectedAndTheActiveOneIsUndisturbed() async throws {
        let log = Log(), runtime = FeatureRuntime()
        let alone = FeatureNode("alone") { Probe(name: "alone", log: log) }
        try runtime.set([alone])
        await runtime.settled()
        XCTAssertThrowsError(try runtime.set([alone, alone]))
        XCTAssertThrowsError(try runtime.set([alone, FeatureNode("p1") { Provider(log: log, wire: Wire()) },
                                              FeatureNode("p2") { Provider(log: log, wire: Wire()) }]))
        XCTAssertThrowsError(try runtime.set([FeatureNode("a/b") { Probe(name: "x", log: log) }]))
        await runtime.settled()
        XCTAssertEqual(runtime.statuses.map(\.id), ["alone"])
        XCTAssertEqual(log.count("alone"), 1)
        await runtime.shutdown()
    }

    func testDependencyCyclesStayPendingAndSaySo() async throws {
        enum A: ServiceKey { typealias Value = Int }
        enum B: ServiceKey { typealias Value = Int }
        struct NeedsB: Feature {
            @Need(B.self) var b
            @Offer(A.self) var a
            @MainActor func run(_ context: FeatureContext) async throws { a.set(1) }
        }
        struct NeedsA: Feature {
            @Need(A.self) var a
            @Offer(B.self) var b
            @MainActor func run(_ context: FeatureContext) async throws { b.set(2) }
        }
        let runtime = FeatureRuntime()
        try runtime.set {
            FeatureNode("a") { NeedsB() }
            FeatureNode("b") { NeedsA() }
        }
        await runtime.settled()
        for status in runtime.statuses {
            guard case .pending(let reason) = status.phase else { return XCTFail("Loaded a dependency cycle") }
            XCTAssertTrue(reason.contains("cycle"), reason)
        }
        await runtime.shutdown()
    }

    func testRepeatedToggleLeavesNoResourcesAndUnrelatedFeatureIsUnchanged() async throws {
        struct Resource: Feature {
            @Constant var log: Log
            @MainActor func run(_ context: FeatureContext) async throws {
                log.counts["resources", default: 0] += 1
                let log = log
                try context.effect("resource") { log.counts["resources"]! -= 1 }
            }
        }
        let log = Log(), runtime = FeatureRuntime()
        let unrelated = FeatureNode("u") { Probe(name: "unrelated", log: log) }
        for _ in 0..<100 {
            try runtime.set([FeatureNode("r") { Resource(log: log) }, unrelated])
            await runtime.settled()
            XCTAssertEqual(log.count("resources"), 1)
            try runtime.set([unrelated])
            await runtime.settled()
            XCTAssertEqual(log.count("resources"), 0)
        }
        XCTAssertEqual(log.count("unrelated"), 1)
        await runtime.shutdown()
    }

    func testColdLoadAndIncrementalEditsConverge() async throws {
        func tree(_ log: Log, provider: Bool) -> [FeatureNode] {
            var nodes = [FeatureNode("c") { Consumer(log: log, captured: Captured()) }]
            if provider { nodes.append(FeatureNode("p") { Provider(log: log, wire: Wire()) }) }
            return nodes
        }
        let cold = FeatureRuntime(), incremental = FeatureRuntime(), log = Log()
        try cold.set(tree(log, provider: true))
        try incremental.set(tree(log, provider: false))
        await incremental.settled()
        try incremental.set([])
        await incremental.settled()
        try incremental.set(tree(log, provider: true))
        await cold.settled(); await incremental.settled()
        XCTAssertEqual(cold.statuses.map(\.id), incremental.statuses.map(\.id))
        XCTAssertEqual(cold.statuses.map(\.phase), incremental.statuses.map(\.phase))
        XCTAssertTrue(cold.statuses.allSatisfy(\.isActive))
        await cold.shutdown(); await incremental.shutdown()
    }

    func testShutdownCanBeFollowedByARestart() async throws {
        let log = Log(), runtime = FeatureRuntime()
        let tree = [FeatureNode("a") { Probe(name: "a", log: log) }]
        try runtime.set(tree)
        await runtime.settled()
        let unfinished = await runtime.shutdown()
        XCTAssertTrue(unfinished.isEmpty)
        try runtime.set(tree)
        await runtime.settled()
        XCTAssertEqual(log.count("a"), 2)
        XCTAssertEqual(phase(runtime, "a"), .active)
        await runtime.shutdown()
    }
}
