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

    init(service: any LoginItemServicing = MainAppLoginItemService()) {
        self.service = service
        state = LaunchAtLoginModel.state(for: service.status)
    }

    /// Re-reads the authoritative system status, including changes the user
    /// made directly in System Settings while RelayBar was inactive.
    func refresh() {
        state = LaunchAtLoginModel.state(for: service.status)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != state.isEnabled else { return }
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
        service.openLoginItemsSettings()
    }

    private static func state(for status: LoginItemStatus) -> LaunchAtLoginState {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        }
    }
}
