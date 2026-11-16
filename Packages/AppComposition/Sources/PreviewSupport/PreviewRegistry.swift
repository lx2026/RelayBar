import Combine
import Composition
import Foundation

public struct PreviewDescriptor: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let extensions: Set<String>
    public let maximumBytes: Int64
    public init(id: String, title: String, extensions: Set<String>, maximumBytes: Int64) {
        self.id = id; self.title = title; self.extensions = extensions; self.maximumBytes = maximumBytes
    }
}

@MainActor
public struct PreviewResource<Content> {
    public let content: Content
    public let stop: @MainActor () -> Void
    public let dispose: @MainActor () async -> Void
    public init(_ content: Content, stop: @escaping @MainActor () -> Void = {}, dispose: @escaping @MainActor () async -> Void = {}) {
        self.content = content; self.stop = stop; self.dispose = dispose
    }
}

@MainActor
public final class PreviewSession<Content> {
    public let id = UUID()
    public let kind: String
    public let content: Content
    public private(set) var isClosed = false
    public var onClose: (@MainActor () -> Void)?
    fileprivate var unregister: (@MainActor () -> Void)?
    private let effects = EffectScope()
    private let stop: @MainActor () -> Void
    fileprivate init(kind: String, resource: PreviewResource<Content>) throws {
        self.kind = kind; content = resource.content; stop = resource.stop
        try effects.own(resource.dispose)
    }
    public func invalidate() {
        guard !isClosed else { return }
        isClosed = true
        stop()
        onClose?(); onClose = nil
    }
    public func close() async {
        invalidate()
        await effects.dispose()
        unregister?(); unregister = nil
    }
}

/// The owner's handle on one registered format. The feature that registered it ties these to its scope:
/// `invalidate` on withdrawal, `close` as the awaited cleanup.
@MainActor
public final class PreviewRegistration {
    private let invalidation: @MainActor () -> Void
    private let closing: @MainActor () async -> Void
    fileprivate init(invalidate: @escaping @MainActor () -> Void, close: @escaping @MainActor () async -> Void) {
        invalidation = invalidate; closing = close
    }
    /// Stops admitting requests and removes the format from the registry at once.
    public func invalidate() { invalidation() }
    /// Cancels in-flight rendering and closes every result this registration produced.
    public func close() async { invalidation(); await closing() }
}

/// A registration owns both in-flight rendering and every live result it produced.
@MainActor
public final class FilePreviewRegistry<Request, Content>: ObservableObject {
    @MainActor private final class Registration {
        let descriptor: PreviewDescriptor
        let render: @MainActor (Request) async throws -> PreviewResource<Content>
        let effects = EffectScope()
        var sessions: [UUID: PreviewSession<Content>] = [:]
        var active = true
        let ownerIsActive: @MainActor () -> Bool
        init(_ descriptor: PreviewDescriptor, ownerIsActive: @escaping @MainActor () -> Bool,
             render: @escaping @MainActor (Request) async throws -> PreviewResource<Content>) {
            self.descriptor = descriptor; self.ownerIsActive = ownerIsActive; self.render = render
        }
    }
    private var registrations: [String: Registration] = [:]
    @Published public private(set) var descriptors: [PreviewDescriptor] = []
    public init() {}

    public func descriptor(for filename: String) -> PreviewDescriptor? {
        let ext = (filename as NSString).pathExtension.lowercased()
        return descriptors.first { $0.extensions.contains(ext) }
    }

    /// Registers a format. `isActive` reports whether the owning feature may still serve requests.
    public func register(_ descriptor: PreviewDescriptor, isActive: @escaping @MainActor () -> Bool,
                         render: @escaping @MainActor (Request) async throws -> PreviewResource<Content>) throws -> PreviewRegistration {
        guard descriptor.maximumBytes > 0, !descriptor.extensions.isEmpty,
              registrations[descriptor.id] == nil,
              descriptors.allSatisfy({ $0.extensions.isDisjoint(with: descriptor.extensions) }) else {
            throw CompositionError("Conflicting or invalid preview registration \(descriptor.id).")
        }
        let registration = Registration(descriptor, ownerIsActive: isActive, render: render)
        registrations[descriptor.id] = registration; publish()
        return PreviewRegistration(invalidate: { [weak self] in
            registration.active = false
            registration.effects.invalidate()
            if self?.registrations[descriptor.id] === registration {
                self?.registrations.removeValue(forKey: descriptor.id); self?.publish()
            }
        }, close: {
            await registration.effects.dispose()
            for session in Array(registration.sessions.values) { await session.close() }
            registration.sessions.removeAll()
        })
    }

    /// Registers a format for the lifetime of a feature.
    public func register(_ descriptor: PreviewDescriptor, in context: FeatureContext,
                         render: @escaping @MainActor (Request) async throws -> PreviewResource<Content>) throws {
        let registration = try register(descriptor, isActive: { [weak context] in context?.isActive == true }, render: render)
        do {
            try context.effect("\(descriptor.id) preview", cancel: { registration.invalidate() }) { await registration.close() }
        } catch { registration.invalidate(); throw error }
    }

    public func open(filename: String, bytes: Int64?, request: Request) async throws -> PreviewSession<Content> {
        guard let descriptor = descriptor(for: filename) else { throw CompositionError("Preview is disabled or unavailable for this file.") }
        return try await open(kind: descriptor.id, bytes: bytes, request: request)
    }

    public func open(kind: String, bytes: Int64?, request: Request) async throws -> PreviewSession<Content> {
        guard let registration = registrations[kind], registration.active, registration.ownerIsActive() else {
            throw CompositionError("Preview is disabled or unavailable for this file.")
        }
        let descriptor = registration.descriptor
        if let bytes, bytes > descriptor.maximumBytes { throw CompositionError("This file exceeds the \(descriptor.title) preview limit.") }
        let session = try await registration.effects.run { [registration] in
            let resource = try await registration.render(request)
            guard registration.active, !Task.isCancelled else { resource.stop(); await resource.dispose(); throw CancellationError() }
            let session = try PreviewSession(kind: descriptor.id, resource: resource)
            registration.sessions[session.id] = session
            session.unregister = { [weak registration, weak session] in
                if let session { registration?.sessions.removeValue(forKey: session.id) }
            }
            return session
        }
        guard registration.active, !Task.isCancelled else { await session.close(); throw CancellationError() }
        return session
    }

    private func publish() { descriptors = registrations.values.map(\.descriptor).sorted { $0.id < $1.id } }
}
