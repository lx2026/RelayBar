import Composition
import Foundation

/// Linked only by test targets to show that a feature from another module joins a tree
/// with nothing but a node: it owns a temporary file and a notification observer.
public struct FileProbe: Feature {
    public let file: URL
    public let notification: String
    public init(file: URL, notification: String) { self.file = file; self.notification = notification }

    @MainActor public func run(_ context: FeatureContext) async throws {
        let file = file
        try Data("active".utf8).write(to: file, options: .atomic)
        try context.effect("probe file") { try? FileManager.default.removeItem(at: file) }
        try context.effects.observe(name: Notification.Name(notification)) { _ in
            try? Data("observed".utf8).write(to: file, options: .atomic)
        }
    }
}
