import Combine
import XCTest
@testable import RelayBar

@MainActor
private final class UpdateServiceSpy: UpdateServicing {
    var isAvailable = true
    var automaticallyChecksForUpdates = false
    var canCheckForUpdates = true
    var deferredInstallTunnelCount: Int?
    var stateDidChange: (@MainActor () -> Void)?
    private(set) var checkCount = 0
    private(set) var stopCount = 0
    var pendingCheck: (@MainActor (UpdateCheckResult) -> Void)?

    func start() {}
    func stop() async { stopCount += 1; stateDidChange = nil }

    func checkForUpdates(
        completion: @escaping @MainActor (UpdateCheckResult) -> Void
    ) {
        checkCount += 1
        pendingCheck = completion
    }

    func complete(with result: UpdateCheckResult) {
        let completion = pendingCheck
        pendingCheck = nil
        completion?(result)
    }

    func prepareForApplicationTermination() -> Bool { false }
}

@MainActor
final class UpdateModelTests: XCTestCase {
    func testWithdrawalBlocksStaleModelAndLateCompletionWithoutChangingPreference() async {
        let service = UpdateServiceSpy(), announcer = AccessibilityAnnouncerSpyForUpdates()
        service.automaticallyChecksForUpdates = true
        var active = true
        let model = UpdateModel(service: service, announcer: announcer, available: { active })
        model.checkForUpdates()
        active = false
        model.setAutomaticallyChecksForUpdates(false)
        service.complete(with: .available)
        XCTAssertEqual(announcer.messages, ["Checking for updates"])
        await model.stop(); await model.stop()
        model.checkForUpdates()
        XCTAssertFalse(model.canCheckForUpdates)
        XCTAssertFalse(model.isAvailable)
        XCTAssertEqual(service.stopCount, 1)
        XCTAssertEqual(service.checkCount, 1)
        XCTAssertTrue(service.automaticallyChecksForUpdates)
    }

    private func makeModel(service: UpdateServiceSpy) -> UpdateModel {
        UpdateModel(
            service: service,
            announcer: AccessibilityAnnouncerSpyForUpdates()
        )
    }

    func testAutomaticPreferenceReadsAndWritesThroughAuthoritativeService() {
        let service = UpdateServiceSpy()
        service.automaticallyChecksForUpdates = true
        let model = makeModel(service: service)

        XCTAssertTrue(model.automaticallyChecksForUpdates)

        model.setAutomaticallyChecksForUpdates(false)

        XCTAssertFalse(service.automaticallyChecksForUpdates)
        XCTAssertFalse(model.automaticallyChecksForUpdates)
    }

    func testManualCheckMapsCurrentResultToTransientAccessibleState() {
        let service = UpdateServiceSpy()
        let announcer = AccessibilityAnnouncerSpyForUpdates()
        let model = UpdateModel(service: service, announcer: announcer)

        model.checkForUpdates()
        XCTAssertEqual(model.state, .checking)
        XCTAssertEqual(service.checkCount, 1)

        service.complete(with: .upToDate)

        XCTAssertEqual(model.state, .upToDate)
        XCTAssertEqual(
            announcer.messages,
            ["Checking for updates", "RelayBar is up to date"]
        )

        model.cancelTransientState()
        XCTAssertEqual(model.state, .idle)
    }

    func testAvailableResultCompletesTheSingleUserInitiatedCheck() {
        let service = UpdateServiceSpy()
        let model = makeModel(service: service)

        model.checkForUpdates()
        service.complete(with: .available)

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(service.checkCount, 1)
    }

    func testFailureIsRetryableAndDoesNotPersistAcrossSettingsSession() {
        let service = UpdateServiceSpy()
        let model = makeModel(service: service)

        model.checkForUpdates()
        service.complete(with: .failed)
        XCTAssertEqual(model.state, .failed)

        model.cancelTransientState()
        XCTAssertEqual(model.state, .idle)

        model.checkForUpdates()
        XCTAssertEqual(service.checkCount, 2)
    }

    func testUnavailableServiceCannotEnableOrProbe() {
        let service = UpdateServiceSpy()
        service.isAvailable = false
        let model = makeModel(service: service)

        model.setAutomaticallyChecksForUpdates(true)
        model.checkForUpdates()

        XCTAssertFalse(model.isAvailable)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
        XCTAssertEqual(service.checkCount, 0)
        XCTAssertEqual(model.state, .idle)
    }

    func testConcurrentManualChecksAreCoalesced() {
        let service = UpdateServiceSpy()
        let model = makeModel(service: service)

        model.checkForUpdates()
        model.checkForUpdates()

        XCTAssertEqual(service.checkCount, 1)
    }

    func testResultCompletingAfterSettingsClosesDoesNotPersistInlineClaim() {
        let service = UpdateServiceSpy()
        let model = makeModel(service: service)

        model.checkForUpdates()
        model.cancelTransientState()
        service.complete(with: .upToDate)

        XCTAssertEqual(model.state, .idle)
    }

    func testDeferredInstallStateRemainsVisibleAcrossSettingsSessions() {
        let service = UpdateServiceSpy()
        let model = makeModel(service: service)

        service.deferredInstallTunnelCount = 2
        service.stateDidChange?()
        XCTAssertEqual(model.state, .waitingForTunnels(2))
        XCTAssertFalse(model.canCheckForUpdates)

        model.cancelTransientState()
        XCTAssertEqual(model.state, .waitingForTunnels(2))

        service.deferredInstallTunnelCount = nil
        service.stateDidChange?()
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.canCheckForUpdates)
    }

    func testMaintainerFeedAcceptsOnlyExplicitLoopbackHTTPURLs() {
        XCTAssertEqual(
            MaintainerUpdateFeed.validatedURLString(
                "http://127.0.0.1:8765/appcast.xml"
            ),
            "http://127.0.0.1:8765/appcast.xml"
        )
        XCTAssertEqual(
            MaintainerUpdateFeed.validatedURLString(
                "http://[::1]:8765/appcast.xml"
            ),
            "http://[::1]:8765/appcast.xml"
        )
        XCTAssertNil(
            MaintainerUpdateFeed.validatedURLString(
                "https://127.0.0.1:8765/appcast.xml"
            )
        )
        XCTAssertNil(
            MaintainerUpdateFeed.validatedURLString(
                "http://192.168.1.10:8765/appcast.xml"
            )
        )
        XCTAssertNil(
            MaintainerUpdateFeed.validatedURLString(
                "http://localhost/appcast.xml"
            )
        )
        XCTAssertNil(
            MaintainerUpdateFeed.validatedURLString(
                "http://localhost:8765"
            )
        )
    }

    func testMaintainerFeedRequiresOneProcessScopedLaunchArgument() {
        let validArguments = [
            "RelayBar",
            MaintainerUpdateFeed.launchArgument,
            "http://127.0.0.1:8765/appcast.xml"
        ]
        XCTAssertTrue(MaintainerUpdateFeed.wasRequested(arguments: validArguments))
        XCTAssertEqual(
            MaintainerUpdateFeed.urlString(arguments: validArguments),
            "http://127.0.0.1:8765/appcast.xml"
        )
        XCTAssertNil(MaintainerUpdateFeed.urlString(arguments: ["RelayBar"]))
        XCTAssertNil(
            MaintainerUpdateFeed.urlString(arguments: [
                "RelayBar",
                MaintainerUpdateFeed.launchArgument
            ])
        )
        XCTAssertNil(
            MaintainerUpdateFeed.urlString(arguments: validArguments + [
                MaintainerUpdateFeed.launchArgument,
                "http://localhost:8765/appcast.xml"
            ])
        )
    }

    func testRelaunchWithoutActiveTunnelsDoesNotInterrupt() {
        let prompt = UpdateInstallPromptSpy(decision: .stopAndInstall)
        let gate = UpdateRelaunchGate(
            activeTunnelCount: { 0 },
            stopAllTunnels: {},
            prompt: prompt
        )

        XCTAssertFalse(gate.shouldPostpone(installHandler: {}))
        XCTAssertTrue(prompt.presentedCounts.isEmpty)
    }

    func testDisposingRelaunchGateCannotInvokeDeferredInstall() async {
        var activeCount = 1, installs = 0
        let gate = UpdateRelaunchGate(activeTunnelCount: { activeCount }, stopAllTunnels: { activeCount = 0 },
            prompt: UpdateInstallPromptSpy(decision: .waitForTunnels))
        XCTAssertTrue(gate.shouldPostpone { installs += 1 })
        await gate.stop()
        activeCount = 0
        gate.installDeferredUpdateIfReady()
        XCTAssertFalse(gate.prepareForApplicationTermination())
        XCTAssertEqual(installs, 0)
    }

    func testProceedNamesCountStopsTunnelsThenResumesInstall() {
        var activeCount = 2
        var installCount = 0
        let prompt = UpdateInstallPromptSpy(decision: .stopAndInstall)
        let gate = UpdateRelaunchGate(
            activeTunnelCount: { activeCount },
            stopAllTunnels: { activeCount = 0 },
            prompt: prompt
        )

        XCTAssertTrue(
            gate.shouldPostpone(installHandler: { installCount += 1 })
        )
        gate.installDeferredUpdateIfReady()

        XCTAssertEqual(prompt.presentedCounts, [2])
        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(installCount, 1)
    }

    func testDeferLeavesTunnelsRunningUntilTheyAreStopped() {
        var activeCount = 3
        var installCount = 0
        let prompt = UpdateInstallPromptSpy(
            decision: .waitForTunnels
        )
        let gate = UpdateRelaunchGate(
            activeTunnelCount: { activeCount },
            stopAllTunnels: { activeCount = 0 },
            prompt: prompt
        )

        XCTAssertTrue(
            gate.shouldPostpone(installHandler: { installCount += 1 })
        )
        XCTAssertEqual(prompt.presentedCounts, [3])
        XCTAssertEqual(activeCount, 3)
        XCTAssertEqual(installCount, 0)

        activeCount = 0
        gate.installDeferredUpdateIfReady()
        XCTAssertEqual(installCount, 1)
    }

    func testQuitAfterDeferralStopsTunnelsAndHandsBackToInstaller() {
        var activeCount = 1
        var processesStopped = false
        var installCount = 0
        let gate = UpdateRelaunchGate(
            activeTunnelCount: { activeCount },
            tunnelsHaveStopped: { processesStopped },
            stopAllTunnels: { activeCount = 0 },
            prompt: UpdateInstallPromptSpy(
                decision: .waitForTunnels
            )
        )
        _ = gate.shouldPostpone(installHandler: { installCount += 1 })

        XCTAssertTrue(gate.prepareForApplicationTermination())
        XCTAssertEqual(activeCount, 0)
        XCTAssertEqual(installCount, 0)
        XCTAssertTrue(gate.prepareForApplicationTermination())

        processesStopped = true
        gate.installDeferredUpdateIfReady()
        XCTAssertEqual(installCount, 1)
        XCTAssertFalse(gate.prepareForApplicationTermination())
    }

    func testDeferredCountStaysPositiveWhileSSHProcessesTerminate() {
        var activeCount = 1
        var processesStopped = false
        var displayedCounts: [Int?] = []
        let gate = UpdateRelaunchGate(
            activeTunnelCount: { activeCount },
            tunnelsHaveStopped: { processesStopped },
            stopAllTunnels: { activeCount = 0 },
            prompt: UpdateInstallPromptSpy(decision: .stopAndInstall),
            deferredStateDidChange: { displayedCounts.append($0) }
        )

        XCTAssertTrue(gate.shouldPostpone(installHandler: {}))
        gate.installDeferredUpdateIfReady()
        XCTAssertEqual(displayedCounts.last!, 1)

        processesStopped = true
        gate.installDeferredUpdateIfReady()
        XCTAssertNil(displayedCounts.last!)
    }

    func testPublishedShutdownObservationEvaluatesSettledProcessState() async {
        let state = UpdateShutdownState()
        var installCount = 0
        let gate = UpdateRelaunchGate(
            activeTunnelCount: { state.activeCount },
            tunnelsHaveStopped: {
                state.activeCount == 0 && state.terminatingProcessCount == 0
            },
            stopAllTunnels: {},
            prompt: UpdateInstallPromptSpy(decision: .waitForTunnels)
        )
        let observation = state.$activeCount
            .combineLatest(state.$terminatingProcessCount)
            .sink { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    gate.installDeferredUpdateIfReady()
                }
            }

        XCTAssertTrue(
            gate.shouldPostpone(installHandler: { installCount += 1 })
        )
        state.activeCount = 0
        state.terminatingProcessCount = 1
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(installCount, 0)

        state.terminatingProcessCount = 0
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(installCount, 1)
        withExtendedLifetime(observation) {}
    }
}

@MainActor
private final class UpdateShutdownState: ObservableObject {
    @Published var activeCount = 1
    @Published var terminatingProcessCount = 0
}

@MainActor
private final class AccessibilityAnnouncerSpyForUpdates: AccessibilityAnnouncing {
    private(set) var messages: [String] = []

    func announce(_ message: String) {
        messages.append(message)
    }
}

@MainActor
private final class UpdateInstallPromptSpy: UpdateInstallPrompting {
    let selectedDecision: UpdateInstallDecision
    private(set) var presentedCounts: [Int] = []

    init(decision: UpdateInstallDecision) {
        selectedDecision = decision
    }

    func decision(activeTunnelCount: Int) -> UpdateInstallDecision {
        presentedCounts.append(activeTunnelCount)
        return selectedDecision
    }
}
