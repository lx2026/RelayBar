import Combine
import Foundation

public enum FeaturePhase: Equatable, Sendable {
    /// Wanted but not running; the text says what it is waiting for.
    case pending(String)
    case loading
    case active
    /// Withdrawn; waiting for the features that used it to finish unloading.
    case draining
    case unloading
    case failed(String)
    /// A load or cleanup passed its deadline. It is still running, reported, and no longer holds others up.
    case stuck(String)

    var inTransition: Bool {
        switch self {
        case .loading, .draining, .unloading: return true
        default: return false
        }
    }
}

public struct FeatureStatus: Identifiable, Equatable, Sendable {
    public let id: String
    public let phase: FeaturePhase
    /// Increases each time the feature loads.
    public let generation: UInt64
    public var isActive: Bool { phase == .active }
}

/// The shell's typed, observable view of one service. `nil` means it is not available right now.
@MainActor
public final class ServicePort<Value>: ObservableObject {
    @Published public fileprivate(set) var value: Value?
    /// Changes whenever a different binding is published, including a replacement with an equal value.
    @Published public fileprivate(set) var generation = 0
    fileprivate var identity: ObjectIdentifier?
}

/// Converges the running features toward the latest tree. Everything runs on the main actor;
/// concurrency comes from each feature owning its own load or cleanup task.
@MainActor
public final class FeatureRuntime: ObservableObject {
    struct SlotID: Hashable { let realm: String?; let key: ObjectIdentifier }

    final class Binding {
        let slot: SlotID, name: String, owner: String, value: Any
        var live = false
        init(slot: SlotID, name: String, owner: String, value: Any) {
            self.slot = slot; self.name = name; self.owner = owner; self.value = value
        }
    }

    struct Requirement { let slot: SlotID; let key: ObjectIdentifier; let name: String }

    struct Plan {
        let id: String
        let node: FeatureNode
        let template: any Feature
        let parent: String?
        /// The isolation sets of this node and its ancestors, nearest first.
        let isolation: [Set<ObjectIdentifier>]
        var needs: [Requirement] = []
        var offers: [Requirement] = []
    }

    struct Failure {
        let template: any Feature
        let against: [ObjectIdentifier?]
    }

    final class Fiber {
        let id: String
        var phase: FeaturePhase = .pending("Not loaded yet")
        var generation: UInt64 = 0
        var loaded: Plan?
        var context: FeatureContext?
        var deps: [Binding] = []
        var offered: [ObjectIdentifier: Binding] = [:]
        var task: Task<Void, Never>?
        var cancelled = false
        var failure: Failure?
        var retryRequested = false
        init(id: String) { self.id = id }
    }

    private final class Gate {
        private var used = false
        func open() -> Bool { if used { return false }; used = true; return true }
    }

    private var fibers: [String: Fiber] = [:]
    private var plans: [String: Plan] = [:]
    private var order: [String] = []
    private var providers: [SlotID: String] = [:]
    private var table: [SlotID: Binding] = [:]
    private var ports: [SlotID: (owner: AnyObject, refresh: () -> Void)] = [:]
    private var scheduled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var passWaiters: [CheckedContinuation<Void, Never>] = []

    /// How long one feature's load cancellation or cleanup may take before it is reported as stuck.
    public var deadline: Duration
    @Published public private(set) var statuses: [FeatureStatus] = []
    /// The wanted tree with each feature's phase and its needs, refreshed with `statuses`.
    @Published public private(set) var graph = FeatureGraph(nodes: [], edges: [])
    /// Stuck features, late completions and rejected offers, oldest first.
    @Published public private(set) var diagnostics: [String] = []

    public init(deadline: Duration = .seconds(20)) { self.deadline = deadline }

    // MARK: Desired state

    /// Says what should exist. Synchronous and idempotent: the runtime converges on the latest tree and
    /// skips intermediate ones. An invalid tree is rejected and the current one stays in force.
    public func set(_ tree: [FeatureNode]) throws {
        var nextPlans: [String: Plan] = [:], nextOrder: [String] = []
        func visit(_ nodes: [FeatureNode], parent: String?, isolation: [Set<ObjectIdentifier>], depth: Int) throws {
            guard depth < 32 else { throw CompositionError("Feature tree is deeper than 32 levels.") }
            for node in nodes {
                guard !node.id.isEmpty, !node.id.contains("/") else {
                    throw CompositionError("Invalid feature id “\(node.id)”.")
                }
                let id = parent.map { "\($0)/\(node.id)" } ?? node.id
                guard nextPlans[id] == nil else { throw CompositionError("Duplicate feature \(id).") }
                let levels = [node.isolates] + isolation
                nextPlans[id] = Plan(id: id, node: node, template: node.make(), parent: parent, isolation: levels)
                nextOrder.append(id)
                try visit(node.children, parent: id, isolation: levels, depth: depth + 1)
            }
        }
        try visit(tree, parent: nil, isolation: [], depth: 0)

        var nextProviders: [SlotID: String] = [:]
        for id in nextOrder {
            guard let base = nextPlans[id] else { continue }
            let children = Mirror(reflecting: base.template).children
            func requirement(_ key: ObjectIdentifier, _ name: String) -> Requirement {
                Requirement(slot: Self.slot(key, for: base, in: nextPlans), key: key, name: name)
            }
            var plan = base
            plan.needs = children.compactMap { ($0.value as? AnyNeed).map { requirement($0.key, $0.name) } }
            plan.offers = children.compactMap { ($0.value as? AnyOffer).map { requirement($0.key, $0.name) } }
            for offer in plan.offers {
                if let other = nextProviders[offer.slot] {
                    throw CompositionError("Conflicting providers \(other) and \(id) for \(offer.name).")
                }
                nextProviders[offer.slot] = id
            }
            nextPlans[id] = plan
        }

        plans = nextPlans; order = nextOrder; providers = nextProviders
        for id in order where fibers[id] == nil { fibers[id] = Fiber(id: id) }
        schedule()
    }

    public func set(@FeatureTreeBuilder _ tree: () -> [FeatureNode]) throws { try set(tree()) }

    /// Gives a failed feature another attempt without waiting for its inputs to change.
    public func retry(_ id: String) {
        fibers[id]?.retryRequested = true
        schedule()
    }

    /// Returns when no feature is loading or unloading. Never call this from work a feature owns:
    /// that work is joined before its feature can finish unloading.
    public func settled() async {
        guard isBusy else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Unloads everything, but never waits longer than `deadline`. Returns whatever did not finish, and why.
    @discardableResult
    public func shutdown(deadline: Duration = .seconds(20)) async -> [FeatureStatus] {
        try? set([])
        _ = await within(deadline) { await self.settled() }
        return statuses.filter { if case .pending = $0.phase { return false }; return true }
    }

    public func status(_ id: String) -> FeatureStatus? {
        fibers[id].map { FeatureStatus(id: id, phase: $0.phase, generation: $0.generation) }
    }

    /// How many resources a running feature currently owns. Lets a test show that repeated work returns to baseline.
    public func resources(_ id: String) -> Int { fibers[id]?.context?.effects.count ?? 0 }

    /// Every wanted feature that would unload if `id` were removed from the tree: its descendants and
    /// the consumers of anything it offers, transitively, in tree order and without `id` itself.
    public func dependents(of id: String) -> [String] {
        FeatureGraph.dependents(of: id, order: order, plans: plans, providers: providers)
    }

    /// Wanted features that are not running, with the reason for each.
    public var unavailable: [FeatureStatus] { statuses.filter { $0.phase != .active } }

    /// The current value of a service, for the composition root. `realm` is the id of the isolating node.
    public func service<K: ServiceKey>(_ key: K.Type, realm: String? = nil) -> K.Value? {
        table[SlotID(realm: realm, key: ObjectIdentifier(K.self))]?.value as? K.Value
    }

    public func port<K: ServiceKey>(_ key: K.Type, realm: String? = nil) -> ServicePort<K.Value> {
        let slot = SlotID(realm: realm, key: ObjectIdentifier(K.self))
        if let existing = ports[slot]?.owner as? ServicePort<K.Value> { return existing }
        let port = ServicePort<K.Value>()
        let refresh = { [weak self, weak port] in
            guard let self, let port else { return }
            let binding = self.table[slot], identity = binding.map { ObjectIdentifier($0) }
            guard port.identity != identity else { return }
            port.identity = identity
            port.value = binding?.value as? K.Value
            port.generation += 1
        }
        ports[slot] = (port, refresh)
        refresh()
        return port
    }

    // MARK: Slots

    func publish(owner: String?, generation: UInt64, key: ObjectIdentifier, name: String, value: Any) {
        guard let owner, let fiber = fibers[owner], fiber.generation == generation, !fiber.cancelled,
              let plan = fiber.loaded, fiber.context?.isActive == true,
              let offer = plan.offers.first(where: { $0.key == key }) else { return }
        let replaced = fiber.offered[key]
        if let replaced { revoke(replaced) }
        let binding = Binding(slot: offer.slot, name: name, owner: owner, value: value)
        fiber.offered[key] = binding
        // An offer made while loading becomes visible when its feature becomes active.
        if fiber.phase == .active { install(binding) }
        if replaced != nil { withdrawDependents() }
        schedule()
    }

    func withdraw(owner: String?, generation: UInt64, key: ObjectIdentifier) {
        guard let owner, let fiber = fibers[owner], fiber.generation == generation,
              let old = fiber.offered.removeValue(forKey: key) else { return }
        revoke(old)
        withdrawDependents()
        schedule()
    }

    /// Returns once nothing still holds a value this slot offered earlier and has since withdrawn.
    func drained(owner: String?, key: ObjectIdentifier) async {
        guard let owner else { return }
        while fibers.values.contains(where: { other in
            other.id != owner && (other.phase == .active || other.phase.inTransition)
                && other.deps.contains { $0.owner == owner && $0.slot.key == key && !$0.live }
        }) {
            await withCheckedContinuation { passWaiters.append($0) }
        }
    }

    /// Withdrawal is synchronous: by the time a slot's `clear` returns, every feature that depended
    /// on it has stopped admitting work and the shell's ports no longer show it. Cleanup follows.
    private func withdrawDependents() {
        var changed = true
        while changed {
            changed = false
            for fiber in fibers.values where isRunning(fiber) && isStale(fiber) {
                retire(fiber)
                changed = true
            }
        }
        for port in ports.values { port.refresh() }
    }

    private func install(_ binding: Binding) {
        if let existing = table[binding.slot], existing !== binding, existing.live {
            note("\(binding.owner) and \(existing.owner) both offered \(binding.name); kept \(existing.owner)")
            return
        }
        binding.live = true
        table[binding.slot] = binding
    }

    private func revoke(_ binding: Binding) {
        binding.live = false
        if table[binding.slot] === binding { table[binding.slot] = nil }
    }

    private static func slot(_ key: ObjectIdentifier, for plan: Plan, in plans: [String: Plan]) -> SlotID {
        // Walk from this node outward to the nearest one that isolates the key.
        var id: String? = plan.id
        for level in plan.isolation {
            if level.contains(key) { return SlotID(realm: id, key: key) }
            id = id.flatMap { plans[$0]?.parent }
        }
        return SlotID(realm: nil, key: key)
    }

    // MARK: Convergence

    private var isBusy: Bool { scheduled || fibers.values.contains { $0.phase.inTransition } }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in self.step() }
    }

    /// One synchronous pass. A feature already in a transition is left alone and calls back here when it lands.
    private func step() {
        scheduled = false

        // 1. Withdraw, synchronously, everything that should no longer be running. Withdrawal cascades.
        withdrawDependents()

        // 2. Clean up each withdrawn feature once nothing that used it is still alive. Unrelated ones overlap.
        for fiber in fibers.values where fiber.phase == .draining && !hasDependents(fiber) {
            unload(fiber, then: .pending("Unloaded"))
        }

        // 3. A failed feature is retried only when what it failed against has changed, or on request.
        for fiber in fibers.values {
            if case .failed = fiber.phase, shouldRetry(fiber) {
                fiber.failure = nil; fiber.retryRequested = false; fiber.phase = .pending("Retrying")
            }
        }

        // 4. Load whatever is wanted and satisfiable, in tree order. Each load is its own task.
        for id in order {
            if let fiber = fibers[id], case .pending = fiber.phase, let plan = plans[id] { load(fiber, plan) }
        }

        // 5. Forget removed features that are at rest.
        for (id, fiber) in fibers where plans[id] == nil {
            switch fiber.phase {
            case .pending, .failed: fibers[id] = nil
            default: break
            }
        }

        explainCycles()
        let next = (order + fibers.keys.filter { plans[$0] == nil }.sorted()).compactMap(status)
        if next != statuses { statuses = next }
        let nextGraph = FeatureGraph(order: order, plans: plans, fibers: fibers, providers: providers, table: table)
        if nextGraph != graph { graph = nextGraph }
        for port in ports.values { port.refresh() }
        let passed = passWaiters
        passWaiters = []
        for waiter in passed { waiter.resume() }
        if !isBusy {
            let resumed = waiters
            waiters = []
            for waiter in resumed { waiter.resume() }
        }
    }

    private func isRunning(_ fiber: Fiber) -> Bool {
        fiber.phase == .active || (fiber.phase == .loading && !fiber.cancelled)
    }

    private func isStale(_ fiber: Fiber) -> Bool {
        guard let loaded = fiber.loaded else { return false }
        guard let plan = plans[fiber.id] else { return true }
        if plan.isolation != loaded.isolation || !loaded.template.isEqual(to: plan.template) { return true }
        if let parent = plan.parent, fibers[parent]?.phase != .active { return true }
        return fiber.deps.contains { !$0.live }
    }

    private func retire(_ fiber: Fiber) {
        for binding in fiber.offered.values { revoke(binding) }
        if fiber.phase == .active {
            fiber.context?.effects.invalidate()
            fiber.phase = .draining
            return
        }
        // A load cannot be interrupted, only asked to stop. Report it if it does not.
        fiber.cancelled = true
        fiber.context?.withdrawnWhileLoading = true
        fiber.task?.cancel()
        let generation = fiber.generation, limit = deadline
        Task { @MainActor [weak self, weak fiber] in
            try? await Task.sleep(for: limit)
            guard let self, let fiber, fiber.generation == generation, fiber.phase == .loading, fiber.cancelled else { return }
            fiber.phase = .stuck("Load did not stop within \(limit)")
            self.note("\(fiber.id): load did not stop within \(limit)")
            self.schedule()
        }
    }

    private func hasDependents(_ fiber: Fiber) -> Bool {
        fibers.values.contains { other in
            guard other !== fiber, other.phase == .active || other.phase.inTransition else { return false }
            return other.loaded?.parent == fiber.id || other.deps.contains { $0.owner == fiber.id }
        }
    }

    private func shouldRetry(_ fiber: Fiber) -> Bool {
        guard let failure = fiber.failure, let plan = plans[fiber.id] else { return false }
        if fiber.retryRequested || !failure.template.isEqual(to: plan.template) { return true }
        return plan.needs.map { table[$0.slot].map { ObjectIdentifier($0) } } != failure.against
    }

    private func load(_ fiber: Fiber, _ plan: Plan) {
        if let parent = plan.parent, fibers[parent]?.phase != .active {
            fiber.phase = .pending("Waiting for \(parent)")
            return
        }
        var deps: [ObjectIdentifier: Binding] = [:]
        for need in plan.needs {
            guard let binding = table[need.slot], binding.live else {
                let source = providers[need.slot].map { "from \($0)" } ?? "which no feature offers"
                fiber.phase = .pending("Needs \(need.name) \(source)")
                return
            }
            deps[need.key] = binding
        }
        let feature = plan.node.make()
        fiber.generation += 1
        let children = Mirror(reflecting: feature).children
        for case let need as AnyNeed in children.map(\.value) { deps[need.key].map { need.fill($0.value) } }
        for case let offer as AnyOffer in children.map(\.value) {
            offer.attach(self, owner: fiber.id, generation: fiber.generation)
        }
        let context = FeatureContext(id: plan.id, generation: fiber.generation)
        fiber.loaded = plan; fiber.context = context; fiber.deps = Array(deps.values)
        fiber.offered = [:]; fiber.cancelled = false; fiber.phase = .loading
        fiber.task = Task { @MainActor in
            var failure: String?
            do { try await feature.run(context) } catch { failure = error.localizedDescription }
            self.landed(fiber, plan: plan, failure: failure)
        }
    }

    private func landed(_ fiber: Fiber, plan: Plan, failure: String?) {
        if failure == nil, !fiber.cancelled {
            fiber.phase = .active
            for binding in fiber.offered.values { install(binding) }
            schedule()
            return
        }
        for binding in fiber.offered.values { revoke(binding) }
        if let failure, !fiber.cancelled {
            fiber.failure = Failure(template: plan.template,
                                    against: plan.needs.map { table[$0.slot].map { ObjectIdentifier($0) } })
            unload(fiber, then: .failed(failure))
        } else {
            unload(fiber, then: .pending("Cancelled while loading"))
        }
    }

    private func unload(_ fiber: Fiber, then rest: FeaturePhase) {
        guard let context = fiber.context else { settle(fiber, rest); return }
        fiber.phase = .unloading
        schedule()
        Task { @MainActor in
            let limit = self.deadline
            if await self.within(limit, { await context.effects.dispose() }) {
                self.settle(fiber, rest)
                return
            }
            // Contained, reported, and no longer holding anything else up. The cleanup itself keeps running.
            let label = context.effects.waitingOn ?? "unknown"
            fiber.phase = .stuck("Cleanup passed \(limit); still waiting on \(label)")
            self.note("\(fiber.id): cleanup passed \(limit); still waiting on \(label)")
            self.schedule()
            await context.effects.dispose()
            self.note("\(fiber.id): late cleanup finished")
            self.settle(fiber, rest)
        }
    }

    private func settle(_ fiber: Fiber, _ rest: FeaturePhase) {
        fiber.context = nil; fiber.loaded = nil; fiber.deps = []; fiber.offered = [:]
        fiber.task = nil; fiber.cancelled = false
        fiber.phase = rest
        schedule()
    }

    /// A dependency cycle can never load. Say so instead of leaving a generic reason.
    private func explainCycles() {
        func walk(_ id: String, path: [String]) {
            if let start = path.firstIndex(of: id) {
                let cycle = Array(path[start...]) + [id]
                for member in cycle { fibers[member]?.phase = .pending("Dependency cycle: " + cycle.joined(separator: " → ")) }
                return
            }
            guard let fiber = fibers[id], case .pending = fiber.phase, let plan = plans[id] else { return }
            for need in plan.needs where table[need.slot]?.live != true {
                if let provider = providers[need.slot] { walk(provider, path: path + [id]) }
            }
        }
        for id in order { walk(id, path: []) }
    }

    private func note(_ line: String) {
        diagnostics.append(line)
        if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
    }

    private func within(_ limit: Duration, _ operation: @escaping @MainActor () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = Gate()
            let timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                if gate.open() { continuation.resume(returning: false) }
            }
            Task { @MainActor in
                await operation()
                timer.cancel()
                if gate.open() { continuation.resume(returning: true) }
            }
        }
    }
}
