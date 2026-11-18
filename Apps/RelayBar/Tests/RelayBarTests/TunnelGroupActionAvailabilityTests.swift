import XCTest
@testable import RelayBar

final class TunnelGroupActionAvailabilityTests: XCTestCase {
    func testEmptyGroupDisablesEveryBatchAction() {
        let availability = TunnelGroupActionAvailability(phases: [])

        XCTAssertFalse(availability.canStartAll)
        XCTAssertFalse(availability.canStopAll)
        XCTAssertFalse(availability.canRestartAll)
    }

    func testInactiveGroupEnablesOnlyStartAll() {
        let availability = TunnelGroupActionAvailability(
            phases: [.stopped, .failed("No route")]
        )

        XCTAssertTrue(availability.canStartAll)
        XCTAssertFalse(availability.canStopAll)
        XCTAssertFalse(availability.canRestartAll)
    }

    func testActiveGroupEnablesStopAndRestart() {
        let availability = TunnelGroupActionAvailability(
            phases: [
                .starting,
                .retrying(attempt: 2, maxAttempts: 10, delay: 1, message: "Retry"),
                .running
            ]
        )

        XCTAssertFalse(availability.canStartAll)
        XCTAssertTrue(availability.canStopAll)
        XCTAssertTrue(availability.canRestartAll)
    }

    func testMixedGroupEnablesEveryBatchAction() {
        let availability = TunnelGroupActionAvailability(
            phases: [.running, .stopped]
        )

        XCTAssertTrue(availability.canStartAll)
        XCTAssertTrue(availability.canStopAll)
        XCTAssertTrue(availability.canRestartAll)
    }
}
