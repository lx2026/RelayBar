import AppKit
import Foundation

struct ApplicationMetadata: Equatable {
    let name: String
    let version: String?
    let build: String?

    init(
        infoDictionary: [String: Any],
        fallbackName: String = "RelayBar"
    ) {
        name = ApplicationMetadata.nonemptyString(
            infoDictionary["CFBundleName"]
        ) ?? fallbackName
        version = ApplicationMetadata.nonemptyString(
            infoDictionary["CFBundleShortVersionString"]
        )
        build = ApplicationMetadata.nonemptyString(
            infoDictionary["CFBundleVersion"]
        )
    }

    static var current: ApplicationMetadata {
        ApplicationMetadata(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    var displayText: String {
        switch (version, build) {
        case let (.some(version), .some(build)):
            "\(name) \(version) (\(build))"
        case let (.some(version), .none):
            "\(name) \(version)"
        case let (.none, .some(build)):
            "\(name) build \(build)"
        case (.none, .none):
            "\(name) version unavailable"
        }
    }

    var accessibilityLabel: String {
        switch (version, build) {
        case let (.some(version), .some(build)):
            "\(name) version \(version), build \(build)"
        case let (.some(version), .none):
            "\(name) version \(version)"
        case let (.none, .some(build)):
            "\(name) version unavailable, build \(build)"
        case (.none, .none):
            "\(name) version unavailable"
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RelayBarProjectLink {
    static let website = URL(string: "https://lx2026.github.io/RelayBar/")!
    static let repository = URL(string: "https://github.com/lx2026/RelayBar")!
}

@MainActor
protocol ExternalLinkOpening {
    @discardableResult
    func open(_ url: URL) -> Bool
}

@MainActor
protocol PasteboardWriting {
    @discardableResult
    func write(_ string: String) -> Bool
}

@MainActor
protocol AccessibilityAnnouncing {
    func announce(_ message: String)
}

@MainActor
struct WorkspaceExternalLinkOpener: ExternalLinkOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
struct SystemPasteboardWriter: PasteboardWriting {
    func write(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }
}

@MainActor
struct SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}

@MainActor
final class ApplicationAboutModel: ObservableObject {
    @Published private(set) var didCopyVersion = false

    let metadata: ApplicationMetadata

    private let linkOpener: any ExternalLinkOpening
    private let pasteboardWriter: any PasteboardWriting
    private let announcer: any AccessibilityAnnouncing
    private let confirmationDuration: Duration
    private var confirmationTask: Task<Void, Never>?

    init(
        metadata: ApplicationMetadata = .current,
        linkOpener: any ExternalLinkOpening = WorkspaceExternalLinkOpener(),
        pasteboardWriter: any PasteboardWriting = SystemPasteboardWriter(),
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        confirmationDuration: Duration = .milliseconds(1_500)
    ) {
        self.metadata = metadata
        self.linkOpener = linkOpener
        self.pasteboardWriter = pasteboardWriter
        self.announcer = announcer
        self.confirmationDuration = confirmationDuration
    }

    func copyVersion() {
        guard pasteboardWriter.write(metadata.displayText) else { return }

        confirmationTask?.cancel()
        didCopyVersion = true
        announcer.announce("Copied")
        confirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: confirmationDuration)
            guard !Task.isCancelled else { return }
            didCopyVersion = false
        }
    }

    func openWebsite() {
        linkOpener.open(RelayBarProjectLink.website)
    }

    func openRepository() {
        linkOpener.open(RelayBarProjectLink.repository)
    }

    func cancelTransientState() {
        confirmationTask?.cancel()
        confirmationTask = nil
        didCopyVersion = false
    }
}
