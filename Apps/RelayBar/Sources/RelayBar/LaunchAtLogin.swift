import Foundation
import ServiceManagement

/// The login-item states the system service can report for the main app.
enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// Boundary over `SMAppService.mainApp` so login-item behavior is testable
/// without touching the developer machine's real registration.
protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

struct MainAppLoginItemService: LoginItemServicing {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum LaunchAtLoginState: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case error(status: LoginItemStatus, message: String)

    var isEnabled: Bool {
        switch self {
        case .enabled:
            true
        case .error(status: .enabled, message: _):
            true
        case .notRegistered, .requiresApproval, .notFound, .error:
            false
        }
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState

    private let service: any LoginItemServicing
    private let available: () -> Bool
    private var stopped = false

    init(service: any LoginItemServicing = MainAppLoginItemService(), available: @escaping () -> Bool = { true }) {
        self.service = service
        self.available = available
        state = LaunchAtLoginModel.state(for: service.status)
    }

    /// Re-reads the authoritative system status, including changes the user
    /// made directly in System Settings while RelayBar was inactive.
    func refresh() {
        guard !stopped, available() else { return }
        state = LaunchAtLoginModel.state(for: service.status)
    }

    func setEnabled(_ enabled: Bool) {
        guard !stopped, available(), enabled != state.isEnabled else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            let status = service.status
            if enabled, status == .requiresApproval {
                state = .requiresApproval
            } else {
                // Keep the system's status authoritative while retaining the
                // operation error so the control stays truthful and retryable.
                state = .error(
                    status: status,
                    message: error.localizedDescription
                )
            }
        }
    }

    func openLoginItemsSettings() {
        guard !stopped, available() else { return }
        service.openLoginItemsSettings()
    }

    func stop() { stopped = true }

    private static func state(for status: LoginItemStatus) -> LaunchAtLoginState {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        }
    }
}
