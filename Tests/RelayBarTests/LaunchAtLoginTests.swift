import XCTest
@testable import RelayBar

/// Stands in for `SMAppService.mainApp` so these tests never read or change
/// the developer machine's real login-item registration.
final class LoginItemServiceSpy: LoginItemServicing {
    var status: LoginItemStatus
    var registerError: Error?
    var unregisterError: Error?
    var statusAfterRegister: LoginItemStatus?
    var statusAfterUnregister: LoginItemStatus?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let statusAfterRegister {
            status = statusAfterRegister
        }
        if let registerError {
            throw registerError
        }
    }

    func unregister() throws {
        unregisterCount += 1
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
        if let unregisterError {
            throw unregisterError
        }
    }

    func openLoginItemsSettings() {
        openSettingsCount += 1
    }
}

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testInitialStateMirrorsEverySystemStatus() {
        let expectations: [(LoginItemStatus, LaunchAtLoginState)] = [
            (.notRegistered, .notRegistered),
            (.enabled, .enabled),
            (.requiresApproval, .requiresApproval),
            (.notFound, .notFound)
        ]
        for (status, expected) in expectations {
            let model = LaunchAtLoginModel(
                service: LoginItemServiceSpy(status: status)
            )
            XCTAssertEqual(model.state, expected)
        }
    }

    func testEnableRegistersOnceAndReflectsAuthoritativeStatus() {
        let service = LoginItemServiceSpy(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(model.state, .enabled)

        model.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
    }

    func testEnableReportsApprovalRequirementWithoutClaimingEnabled() {
        let succeeding = LoginItemServiceSpy(status: .notRegistered)
        succeeding.statusAfterRegister = .requiresApproval
        let succeedingModel = LaunchAtLoginModel(service: succeeding)

        succeedingModel.setEnabled(true)

        XCTAssertEqual(succeedingModel.state, .requiresApproval)
        XCTAssertFalse(succeedingModel.state.isEnabled)

        let throwing = LoginItemServiceSpy(status: .notRegistered)
        throwing.statusAfterRegister = .requiresApproval
        throwing.registerError = StubError("approval pending")
        let throwingModel = LaunchAtLoginModel(service: throwing)

        throwingModel.setEnabled(true)

        XCTAssertEqual(throwingModel.state, .requiresApproval)
        XCTAssertFalse(throwingModel.state.isEnabled)
    }

    func testEnableFailureSurfacesErrorAndStaysOff() {
        let service = LoginItemServiceSpy(status: .notRegistered)
        service.registerError = StubError("registration failed")
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        XCTAssertEqual(
            model.state,
            .error(status: .notRegistered, message: "registration failed")
        )
        XCTAssertFalse(model.state.isEnabled)
    }

    func testEnableFailureStillReflectsAnAuthoritativeEnabledStatus() {
        let service = LoginItemServiceSpy(status: .notRegistered)
        service.statusAfterRegister = .enabled
        service.registerError = StubError("registration result was uncertain")
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        XCTAssertEqual(
            model.state,
            .error(
                status: .enabled,
                message: "registration result was uncertain"
            )
        )
        XCTAssertTrue(model.state.isEnabled)
    }

    func testDisableUnregistersAndReflectsAuthoritativeStatus() {
        let service = LoginItemServiceSpy(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(model.state, .notRegistered)
    }

    func testDisableFailureSurfacesErrorInsteadOfClaimingDisabled() {
        let service = LoginItemServiceSpy(status: .enabled)
        service.unregisterError = StubError("unregister failed")
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(false)

        XCTAssertEqual(
            model.state,
            .error(status: .enabled, message: "unregister failed")
        )
        XCTAssertTrue(model.state.isEnabled)

        service.unregisterError = nil
        service.statusAfterUnregister = .notRegistered
        model.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 2)
        XCTAssertEqual(model.state, .notRegistered)
    }

    func testRefreshReflectsChangesMadeInSystemSettings() {
        let service = LoginItemServiceSpy(status: .enabled)
        let model = LaunchAtLoginModel(service: service)
        XCTAssertEqual(model.state, .enabled)

        service.status = .requiresApproval
        model.refresh()
        XCTAssertEqual(model.state, .requiresApproval)

        service.status = .enabled
        model.refresh()
        XCTAssertEqual(model.state, .enabled)
    }

    func testRefreshReplacesAStaleErrorWithTheAuthoritativeStatus() {
        let service = LoginItemServiceSpy(status: .notRegistered)
        service.registerError = StubError("transient failure")
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)
        guard case .error(status: .notRegistered, message: _) = model.state else {
            return XCTFail("Expected a surfaced registration error.")
        }

        service.status = .enabled
        model.refresh()

        XCTAssertEqual(model.state, .enabled)
    }

    func testOpenLoginItemsSettingsRoutesThroughTheService() {
        let service = LoginItemServiceSpy(status: .requiresApproval)
        let model = LaunchAtLoginModel(service: service)

        model.openLoginItemsSettings()

        XCTAssertEqual(service.openSettingsCount, 1)
    }
}

private struct StubError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
