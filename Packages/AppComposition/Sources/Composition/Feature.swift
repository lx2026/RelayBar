import Foundation

/// A service is named by a type, like a SwiftUI `EnvironmentKey`.
public protocol ServiceKey {
    associatedtype Value
    static var name: String { get }
}

public extension ServiceKey {
    static var name: String { String(describing: Self.self) }
}

/// A feature is a value. Its stored properties are its whole contract: `@Need` is what it
/// requires, `@Offer` is what it may publish, `@Constant` is supplied by the composition root,
/// and anything else is configuration. A feature reloads when its value changes; the wrappers
/// always compare equal, so the synthesized `==` sees configuration only.
///
/// Initializers must be free of side effects: the runtime builds a value to compare and to
/// read the contract before it decides to load anything.
public protocol Feature: Equatable {
    @MainActor func run(_ context: FeatureContext) async throws
}

extension Feature {
    func isEqual(to other: any Feature) -> Bool { (other as? Self) == self }
}

public struct CompositionError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

protocol AnyNeed {
    var key: ObjectIdentifier { get }
    var name: String { get }
    func fill(_ value: Any)
}

/// A required service. Readable once the feature has loaded, and still readable during its cleanup.
@propertyWrapper
public struct Need<K: ServiceKey>: Equatable, AnyNeed {
    private final class Box { var value: K.Value? }
    private let box = Box()
    public init(_ key: K.Type) {}
    public var wrappedValue: K.Value {
        guard let value = box.value else { preconditionFailure("\(K.name) was read before its feature loaded.") }
        return value
    }
    public static func == (lhs: Need, rhs: Need) -> Bool { true }
    var key: ObjectIdentifier { ObjectIdentifier(K.self) }
    var name: String { K.name }
    func fill(_ value: Any) { box.value = (value as! K.Value) }
}

/// A place a running feature can fill and empty at any time. Dependents load and unload to follow it.
public final class Slot<Value> {
    let key: ObjectIdentifier
    let name: String
    weak var runtime: FeatureRuntime?
    var owner: String?
    var generation: UInt64 = 0
    init(key: ObjectIdentifier, name: String) { self.key = key; self.name = name }

    /// Publishes a value. A different value replaces the binding, so consumers of the old one reload.
    @MainActor public func set(_ value: Value) {
        runtime?.publish(owner: owner, generation: generation, key: key, name: name, value: value)
    }

    /// Withdraws the value. Dependents stop admitting work before this returns; their cleanup follows.
    @MainActor public func clear() {
        runtime?.withdraw(owner: owner, generation: generation, key: key)
    }

    /// Waits until no dependent still holds a value this slot offered and later withdrew or replaced,
    /// so the owner can release that value's resources.
    @MainActor public func drained() async {
        await runtime?.drained(owner: owner, key: key)
    }
}

protocol AnyOffer {
    var key: ObjectIdentifier { get }
    var name: String { get }
    @MainActor func attach(_ runtime: FeatureRuntime, owner: String, generation: UInt64)
}

@propertyWrapper
public struct Offer<K: ServiceKey>: Equatable, AnyOffer {
    private let slot: Slot<K.Value>
    public init(_ key: K.Type) { slot = Slot(key: ObjectIdentifier(K.self), name: K.name) }
    public var wrappedValue: Slot<K.Value> { slot }
    public static func == (lhs: Offer, rhs: Offer) -> Bool { true }
    var key: ObjectIdentifier { ObjectIdentifier(K.self) }
    var name: String { K.name }
    @MainActor func attach(_ runtime: FeatureRuntime, owner: String, generation: UInt64) {
        slot.runtime = runtime; slot.owner = owner; slot.generation = generation
    }
}

/// A value handed in by the composition root (a factory, a store, a test double).
/// It never takes part in the comparison that decides whether a feature reloads.
@propertyWrapper
public struct Constant<Value>: Equatable {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public static func == (lhs: Constant, rhs: Constant) -> Bool { true }
}

/// One entry of the feature tree. The tree is rebuilt from state whenever state changes;
/// a feature that should not exist is simply not returned.
public struct FeatureNode {
    public let id: String
    let make: @MainActor () -> any Feature
    let isolates: Set<ObjectIdentifier>
    let isRealm: Bool
    fileprivate(set) var children: [FeatureNode]

    public init<F: Feature>(_ id: String, isolating: [any ServiceKey.Type] = [],
                            _ make: @escaping @MainActor () -> F,
                            @FeatureTreeBuilder children: () -> [FeatureNode] = { [] }) {
        self.id = id
        isRealm = F.self == RealmFeature.self
        self.make = { make() }
        isolates = Set(isolating.map { ObjectIdentifier($0) })
        self.children = children()
    }

    /// A subtree with its own private copy of the listed services.
    public static func realm(_ id: String, isolating: [any ServiceKey.Type] = [],
                             @FeatureTreeBuilder _ children: () -> [FeatureNode]) -> FeatureNode {
        FeatureNode(id, isolating: isolating, { RealmFeature() }, children: children)
    }
}

extension Array where Element == FeatureNode {
    /// The same tree without the named features (full path ids) and everything below them.
    public func excluding(_ ids: Set<String>) -> [FeatureNode] {
        guard !ids.isEmpty else { return self }
        return pruning { id, _ in ids.contains(id) }
    }

    /// Removes the contributions of these plugins in the realms present in this tree.
    public func excluding(plugins: [PluginDescriptor],
                          where isExcluded: (PluginDescriptor, String?) -> Bool = { _, _ in true }) -> [FeatureNode] {
        guard !plugins.isEmpty else { return self }
        return pruning { id, realm in
            plugins.contains { $0.owns(id, inRealm: realm) && isExcluded($0, realm) }
        }
    }

    private func pruning(_ excludes: (String, String?) -> Bool) -> [FeatureNode] {
        func prune(_ nodes: [FeatureNode], parent: String?, realm: String?) -> [FeatureNode] {
            nodes.compactMap { node in
                let id = parent.map { "\($0)/\(node.id)" } ?? node.id
                guard !excludes(id, realm) else { return nil }
                var kept = node
                kept.children = prune(node.children, parent: id, realm: node.isRealm ? id : realm)
                return kept
            }
        }
        return prune(self, parent: nil, realm: nil)
    }
}

struct RealmFeature: Feature {
    @MainActor func run(_ context: FeatureContext) async throws {}
}

@resultBuilder
public enum FeatureTreeBuilder {
    public static func buildExpression(_ node: FeatureNode) -> [FeatureNode] { [node] }
    public static func buildExpression(_ nodes: [FeatureNode]) -> [FeatureNode] { nodes }
    public static func buildBlock(_ parts: [FeatureNode]...) -> [FeatureNode] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [FeatureNode]?) -> [FeatureNode] { part ?? [] }
    public static func buildEither(first: [FeatureNode]) -> [FeatureNode] { first }
    public static func buildEither(second: [FeatureNode]) -> [FeatureNode] { second }
    public static func buildArray(_ parts: [[FeatureNode]]) -> [FeatureNode] { parts.flatMap { $0 } }
}
