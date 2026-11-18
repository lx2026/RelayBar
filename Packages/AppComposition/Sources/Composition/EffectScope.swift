import Foundation

/// Explicit ownership. Invalidation is synchronous; disposal is idempotent, ordered and awaited.
/// Every entry carries a label so a cleanup that does not finish can be named.
@MainActor
public final class EffectScope {
    private struct Effect {
        let id: UUID
        let label: String
        let cancel: @MainActor () -> Void
        let undo: @MainActor () async -> Void
    }
    private var effects: [Effect] = []
    private var retirement: Task<Void, Never>?
    private var releasing: [UUID: Task<Void, Never>] = [:]
    private var acceptsWork = true
    public private(set) var isDisposed = false
    /// The label of the cleanup step currently being awaited, if any.
    public private(set) var waitingOn: String?
    public var count: Int { effects.count + releasing.count }
    /// False from the moment of invalidation: no new work is admitted and callbacks are rejected.
    public var isOpen: Bool { acceptsWork && !isDisposed }

    public init() {}

    @discardableResult
    public func own(_ label: String, cancel: @escaping @MainActor () -> Void = {},
                    _ undo: @escaping @MainActor () async -> Void) throws -> UUID {
        try register(label, cancel: cancel, undo: undo)
    }

    /// Unlabelled entries are named after the line that registered them.
    @discardableResult
    public func own(cancel: @escaping @MainActor () -> Void = {},
                    file: StaticString = #fileID, line: UInt = #line,
                    _ undo: @escaping @MainActor () async -> Void) throws -> UUID {
        try register("\(file):\(line)", cancel: cancel, undo: undo)
    }

    private func register(_ label: String, cancel: @escaping @MainActor () -> Void,
                          undo: @escaping @MainActor () async -> Void) throws -> UUID {
        guard acceptsWork, retirement == nil, !isDisposed else {
            throw CompositionError("Cannot acquire resources in a retiring scope.")
        }
        let id = UUID()
        effects.append(Effect(id: id, label: label, cancel: cancel, undo: undo))
        return id
    }

    public func release(_ id: UUID) async {
        if let pending = releasing[id] { await pending.value; return }
        guard let index = effects.firstIndex(where: { $0.id == id }) else { return }
        let effect = effects.remove(at: index)
        effect.cancel()
        let task = Task { await effect.undo() }
        releasing[id] = task
        await task.value
        releasing.removeValue(forKey: id)
    }

    /// Forget a resource that has already completed, without accumulating dead ledger entries.
    public func completed(_ id: UUID) { effects.removeAll { $0.id == id } }

    public func dispose() async {
        invalidate()
        if let retirement { await retirement.value; return }
        guard !isDisposed else { return }
        let task = Task { @MainActor in
            // A resource released by its owner is still live until its asynchronous undo ends.
            for pending in Array(self.releasing.values) { await pending.value }
            while let effect = self.effects.popLast() {
                self.waitingOn = effect.label
                await effect.undo()
            }
            for pending in Array(self.releasing.values) { await pending.value }
            self.releasing.removeAll()
            self.waitingOn = nil
            self.isDisposed = true
        }
        retirement = task
        await task.value
        retirement = nil
    }

    /// Close admission synchronously before an owner starts awaiting cleanup.
    public func invalidate() {
        guard acceptsWork else { return }
        acceptsWork = false
        // Cancel every job before joining any one of them: queued jobs may depend on earlier jobs releasing slots.
        for effect in effects { effect.cancel() }
    }

    @discardableResult
    public func task(file: StaticString = #fileID, line: UInt = #line,
                     _ operation: @escaping @MainActor () async -> Void) throws -> Task<Void, Never> {
        try task("\(file):\(line)", operation)
    }

    @discardableResult
    public func task(_ label: String, _ operation: @escaping @MainActor () async -> Void) throws -> Task<Void, Never> {
        guard acceptsWork else { throw CompositionError("Cannot start work in a retiring scope.") }
        var token: UUID?
        let task = Task { @MainActor [weak self] in
            await operation()
            if let token { self?.completed(token) }
        }
        do { token = try register(label, cancel: { task.cancel() }, undo: { await task.value }) }
        catch { task.cancel(); throw error }
        return task
    }

    public func observe(_ center: NotificationCenter = .default, name: Notification.Name,
                        object: AnyObject? = nil, file: StaticString = #fileID, line: UInt = #line,
                        handler: @escaping @Sendable (Notification) -> Void) throws {
        let observer = center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.acceptsWork, !self.isDisposed else { return }
                handler(note)
            }
        }
        do { try own("observer \(name.rawValue) at \(file):\(line)") { center.removeObserver(observer) } }
        catch { center.removeObserver(observer); throw error }
    }

    public func run<Result>(file: StaticString = #fileID, line: UInt = #line,
                            _ operation: @escaping @MainActor () async throws -> Result) async throws -> Result {
        try await run("\(file):\(line)", operation)
    }

    public func run<Result>(_ label: String,
                            _ operation: @escaping @MainActor () async throws -> Result) async throws -> Result {
        guard acceptsWork else { throw CompositionError("Cannot start work in a retiring scope.") }
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await operation()
        }
        let token: UUID
        do { token = try register(label, cancel: { task.cancel() }, undo: { _ = try? await task.value }) }
        catch { task.cancel(); throw error }
        defer { completed(token) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// What a running feature can do. There is no way to reach a service it did not declare.
@MainActor
public final class FeatureContext {
    public let id: String
    /// Increases each time this feature loads; lets a UI tell one instance from its replacement.
    public let generation: UInt64
    public let effects = EffectScope()
    /// Set when a feature is withdrawn while still loading. Its scope stays open until `run` returns,
    /// so a resource acquired late can still register its undo; that undo then runs at once.
    var withdrawnWhileLoading = false

    init(id: String, generation: UInt64) { self.id = id; self.generation = generation }

    /// True from the start of `run` until the feature is withdrawn.
    public var isActive: Bool { effects.isOpen && !withdrawnWhileLoading }

    public func checkActive() throws {
        guard isActive else { throw CompositionError("Feature \(id) is no longer active.") }
        try Task.checkCancellation()
    }

    @discardableResult
    public func effect(_ label: String, cancel: @escaping @MainActor () -> Void = {},
                       _ undo: @escaping @MainActor () async -> Void) throws -> UUID {
        try effects.own(label, cancel: cancel, undo)
    }

    @discardableResult
    public func effect(cancel: @escaping @MainActor () -> Void = {},
                       file: StaticString = #fileID, line: UInt = #line,
                       _ undo: @escaping @MainActor () async -> Void) throws -> UUID {
        try effects.own(cancel: cancel, file: file, line: line, undo)
    }

    /// Owned background work: cancelled on withdrawal and joined before the feature finishes unloading.
    @discardableResult
    public func task(_ label: String, _ operation: @escaping @MainActor () async -> Void) throws -> Task<Void, Never> {
        try effects.task(label, operation)
    }

    @discardableResult
    public func task(file: StaticString = #fileID, line: UInt = #line,
                     _ operation: @escaping @MainActor () async -> Void) throws -> Task<Void, Never> {
        try effects.task(file: file, line: line, operation)
    }

    /// Check, await, check again. A result that arrives after withdrawal is never returned.
    public func perform<Result>(file: StaticString = #fileID, line: UInt = #line,
                                _ operation: @escaping @MainActor () async throws -> Result) async throws -> Result {
        try await perform("\(file):\(line)", operation)
    }

    public func perform<Result>(_ label: String,
                                _ operation: @escaping @MainActor () async throws -> Result) async throws -> Result {
        try checkActive()
        let result = try await effects.run(label, operation)
        try checkActive()
        return result
    }
}
