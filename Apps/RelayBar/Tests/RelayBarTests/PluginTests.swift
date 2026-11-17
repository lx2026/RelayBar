import AppKit
import Combine
import Composition
import CompositionUI
import Foundation
import HouseStyle
import Network
import os
import XCTest
@testable import RelayBar

/// RelayBar's plugin catalog and its plugins, Reconnect on Wake, Service Labels and Open in Frame, run inside
/// the composed app with the fake SSH fixture, an injected event source, injected probes and a private bridge folder.
@MainActor
final class PluginTests: XCTestCase {
    // MARK: Catalog, preferences and window

    func testAPreferenceDocumentWithoutPluginsLoadsDefaultsAndAChoiceSurvivesAReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPlugins-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("preferences.json")
        let saved = #"{"version":1,"preferences":{"automaticallyChecksForUpdates":true,"previews":{},"retryLimit":4}}"#
        try Data(saved.utf8).write(to: url)

        let preferences = PreferenceStore(url: url, initial: RelayBarPreferences()) { try $0.validate() }
        try preferences.load()
        XCTAssertEqual(preferences.value.retryLimit, 4)
        XCTAssertTrue(preferences.value.automaticallyChecksForUpdates)
        for plugin in RelayPlugins.all(frameInstalled: false) + [RelayPlugins.frame(installed: true)] {
            XCTAssertEqual(preferences.value.plugins.isEnabled(plugin), plugin.isOnByDefault, plugin.id)
        }

        try preferences.update { $0.plugins.set(RelayPlugins.services, enabled: true) }
        let reopened = PreferenceStore(url: url, initial: RelayBarPreferences()) { try $0.validate() }
        try reopened.load()
        XCTAssertTrue(reopened.value.plugins.isEnabled(RelayPlugins.services))
        XCTAssertTrue(reopened.value.plugins.isEnabled(RelayPlugins.recovery))
        XCTAssertEqual(reopened.value.retryLimit, 4)
    }

    func testSwitchingAPluginChangesOnlyItsFeatureAndTheChoiceSurvivesARestart() async throws {
        XCTAssertEqual(RelayPlugins.all(frameInstalled: false).map(\.id), ["recovery", "services", "frame", "paper"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPluginSwitch-\(UUID())")
        let url = root.appendingPathComponent("preferences.json")
        let (defaults, suite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let app = makeApp(defaults: defaults, preferencesURL: url)
        await app.start()
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.runtime.status("recovery")?.isActive, true)
        XCTAssertNil(app.runtime.status("services"), "Service Labels is off by default")
        XCTAssertNil(app.serviceLabels)
        let generations = ["tunnels", "updates", "login"].map { app.runtime.status($0)?.generation }

        try await app.setPlugin(RelayPlugins.services, enabled: true)
        XCTAssertEqual(app.runtime.status("services")?.isActive, true)
        XCTAssertNotNil(app.serviceLabels)
        XCTAssertTrue(app.runtime.graph.edges.contains(
            FeatureGraph.Edge(service: "Tunnels", provider: "tunnels", consumer: "services", isSatisfied: true)))
        XCTAssertEqual(app.runtime.dependents(of: "services"), [])
        XCTAssertEqual(app.runtime.dependents(of: "recovery"), [])
        XCTAssertTrue(Set(app.runtime.dependents(of: "tunnels")).isSuperset(of: ["recovery", "services"]))

        try await app.setPlugin(RelayPlugins.recovery, enabled: false)
        XCTAssertNil(app.runtime.status("recovery"))
        XCTAssertFalse(app.isPluginEnabled(RelayPlugins.recovery))
        XCTAssertEqual(["tunnels", "updates", "login"].map { app.runtime.status($0)?.generation }, generations)
        await app.stop()

        let reopened = makeApp(defaults: defaults, preferencesURL: url)
        await reopened.start()
        XCTAssertNil(reopened.runtime.status("recovery"))
        XCTAssertEqual(reopened.runtime.status("services")?.isActive, true)
        await reopened.stop()
    }

    // MARK: Paper Appearance

    /// On by default; switching it changes what every token draws at once, tells open windows to redraw, reloads
    /// no feature, and is stored like any other choice, so the next launch starts in the chosen form.
    func testPaperAppearanceSwitchesThePaletteAtOnceAndTheChoiceSurvivesARestart() async throws {
        defer { HousePalette.apply(.paper) }
        HousePalette.apply(.standard)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayPaper-\(UUID())")
        let url = root.appendingPathComponent("preferences.json")
        let (defaults, suite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let app = makeApp(defaults: defaults, preferencesURL: url)
        XCTAssertEqual(HousePalette.form, .paper, "on by default, applied before anything is shown")
        await app.start()
        XCTAssertTrue(app.isPluginEnabled(RelayPlugins.paperAppearance))
        XCTAssertTrue(app.plugins.contains(RelayPlugins.paperAppearance))
        let ids = app.runtime.statuses.map(\.id)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        func popover() -> NSColor { HousePalette.paper.nsColor.usingColorSpace(.sRGB, in: light) }

        let redraw = expectation(forNotification: HousePalette.didChangeNotification, object: nil)
        try await app.setPlugin(RelayPlugins.paperAppearance, enabled: false)
        await fulfillment(of: [redraw], timeout: 1)
        XCTAssertEqual(HousePalette.form, .standard)
        XCTAssertEqual(popover(), NSColor.windowBackgroundColor.usingColorSpace(.sRGB, in: light))
        XCTAssertEqual(app.runtime.statuses.map(\.id), ids, "no feature comes or goes")
        let stored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(stored.contains(#""paper" : false"#), stored)
        await app.stop()

        HousePalette.apply(.paper)
        let reopened = makeApp(defaults: defaults, preferencesURL: url)
        XCTAssertEqual(HousePalette.form, .standard, "the stored choice applies before the first window")
        await reopened.start()
        XCTAssertFalse(reopened.isPluginEnabled(RelayPlugins.paperAppearance))
        try await reopened.setPlugin(RelayPlugins.paperAppearance, enabled: true)
        XCTAssertEqual(HousePalette.form, .paper)
        XCTAssertEqual(popover(), HousePalette.paper.resolved(in: .paper, appearance: light))
        await reopened.stop()
    }

    func testThePluginsWindowIsMadeOnlyWhenTheAppShowsWindows() async throws {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = makeApp(defaults: defaults)
        await app.start()
        app.showPlugins()
        XCTAssertNil(app.pluginsWindow)

        let composer = PluginComposer(runtime: app.runtime, plugins: app.plugins, isEnabled: app.isPluginEnabled,
                                      setEnabled: { plugin, enabled in try await app.setPlugin(plugin, enabled: enabled) })
        let controller = RelayPluginsWindowController(composer: composer)
        XCTAssertEqual(controller.window.title, "Plugins")
        XCTAssertEqual(controller.window.styleMask, [.titled, .closable, .resizable])
        XCTAssertEqual(controller.window.contentMinSize, NSSize(width: 900, height: 540))
        XCTAssertFalse(controller.window.isReleasedWhenClosed)
        XCTAssertEqual(controller.window.frameAutosaveName, "RelayBarPlugins")
        controller.close()
        await app.stop()
    }

    // MARK: Reconnect on Wake

    func testAnEventStartsTheWaitingAttemptNowAndKeepsTheBudget() async throws {
        let ssh = try makeFakeSSHFixture(overrides: ["RELAYBAR_FAKE_SSH_FAIL_MASTER": "1"])
        let events = ManualRecoveryEvents()
        let app = try await startApp(ssh: ssh, maxRetryAttempts: 3, events: events)
        let store = try XCTUnwrap(app.store)
        let profile = makeProfile(port: 43_310)
        store.add(profile)
        store.start(profile)
        let waiting = await waitUntil { self.attempt(store.phase(for: profile)) == 1 }
        XCTAssertTrue(waiting)
        let listening = await waitUntil { events.started == 1 }
        XCTAssertTrue(listening)

        // Each event makes the attempt the profile was waiting for at once; when it fails, the next one is
        // numbered exactly as it would have been at the end of the 60-second backoff.
        for next in 2...3 {
            events.send()
            let advanced = await waitUntil { self.attempt(store.phase(for: profile)) == next }
            XCTAssertTrue(advanced, "attempt \(next - 1) ran on the event")
            XCTAssertEqual(masterCount(ssh), next)
            guard case .retrying(_, let maximum, let delay, _) = store.phase(for: profile) else {
                return XCTFail("The profile should be waiting again")
            }
            XCTAssertEqual(maximum, 3)
            XCTAssertEqual(delay, 60)
        }
        events.send()
        let exhausted = await waitUntil { self.isFailed(store.phase(for: profile)) }
        XCTAssertTrue(exhausted)
        guard case .failed(let message) = store.phase(for: profile) else { return XCTFail("Expected the budget to run out") }
        XCTAssertTrue(message.contains("Automatic retry stopped after 3 attempts."), message)
        XCTAssertEqual(masterCount(ssh), 4)
    }

    func testTwoEventsInsideTheDebounceWindowMakeOneAttempt() async throws {
        let ssh = try makeFakeSSHFixture(overrides: ["RELAYBAR_FAKE_SSH_FAIL_MASTER": "1"])
        let events = ManualRecoveryEvents()
        let app = try await startApp(ssh: ssh, events: events, debounce: .milliseconds(200))
        let store = try XCTUnwrap(app.store)
        let profile = makeProfile(port: 43_311)
        store.add(profile)
        store.start(profile)
        let waiting = await waitUntil { self.attempt(store.phase(for: profile)) == 1 && events.started == 1 }
        XCTAssertTrue(waiting)

        events.send()
        try await Task.sleep(for: .milliseconds(50))
        events.send()
        XCTAssertEqual(masterCount(ssh), 1, "Nothing runs before the debounce wait ends")
        let advanced = await waitUntil { self.attempt(store.phase(for: profile)) == 2 }
        XCTAssertTrue(advanced)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(masterCount(ssh), 2)
        XCTAssertEqual(attempt(store.phase(for: profile)), 2)
    }

    func testAnEventLeavesFailedAndStoppedProfilesAlone() async throws {
        let ssh = try makeFakeSSHFixture(overrides: ["RELAYBAR_FAKE_SSH_FAIL_MASTER": "1"])
        let events = ManualRecoveryEvents()
        let app = try await startApp(ssh: ssh, events: events)
        let store = try XCTUnwrap(app.store)
        let waiting = makeProfile("Waiting", port: 43_312)
        let stopped = makeProfile("Stopped", port: 43_313)
        var failed = makeProfile("Failed", port: 43_314)
        failed.sshHost = "-invalid"
        for profile in [waiting, stopped, failed] {
            store.add(profile)
            store.start(profile)
        }
        let bothWaiting = await waitUntil {
            self.attempt(store.phase(for: waiting)) == 1 && self.attempt(store.phase(for: stopped)) == 1
        }
        XCTAssertTrue(bothWaiting)
        store.stop(stopped)
        let failure = store.phase(for: failed)
        XCTAssertTrue(isFailed(failure))
        let listening = await waitUntil { events.started == 1 }
        XCTAssertTrue(listening)

        events.send()
        let advanced = await waitUntil { self.attempt(store.phase(for: waiting)) == 2 }
        XCTAssertTrue(advanced)
        XCTAssertEqual(store.phase(for: stopped), .stopped)
        XCTAssertEqual(store.phase(for: failed), failure)
        XCTAssertEqual(masterCount(ssh), 3, "Only the waiting profile launched again")
    }

    func testSwitchingThePluginOffEndsTheStreamCancelsThePendingWaitAndLaterEventsDoNothing() async throws {
        let ssh = try makeFakeSSHFixture(overrides: ["RELAYBAR_FAKE_SSH_FAIL_MASTER": "1"])
        let events = ManualRecoveryEvents()
        let app = try await startApp(ssh: ssh, events: events, debounce: .milliseconds(200))
        let store = try XCTUnwrap(app.store)
        let profile = makeProfile(port: 43_315)
        store.add(profile)
        store.start(profile)
        let waiting = await waitUntil { self.attempt(store.phase(for: profile)) == 1 && events.started == 1 }
        XCTAssertTrue(waiting)

        events.send()
        try await app.setPlugin(RelayPlugins.recovery, enabled: false)
        XCTAssertNil(app.runtime.status("recovery"))
        XCTAssertEqual(events.ended, 1, "Unloading ended the stream, which removes the observers")
        events.send()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(attempt(store.phase(for: profile)), 1)
        XCTAssertEqual(masterCount(ssh), 1)
        XCTAssertEqual(events.started, 1)
    }

    func testRetryNowOutsideAScheduledRetryDoesNothing() async throws {
        let ssh = try makeFakeSSHFixture()
        defer { ssh.cleanup() }
        let profile = makeProfile(port: 43_316)
        let runtime = TunnelProfileRuntime(id: profile.id, sshExecutableURL: fakeSSHURL, maxRetryAttempts: 3,
                                           retryDelayProvider: { _ in 60 }, monotonicNow: { 0 }, browserOpener: { _ in },
                                           processEnvironment: ssh.environment, controlOperationTimeout: 10,
                                           processTerminationGracePeriod: 5)
        runtime.retryNow()
        XCTAssertEqual(runtime.phase, .stopped)
        XCTAssertEqual(masterCount(ssh), 0)

        runtime.start(profile)
        let running = await waitUntil { runtime.phase == .running }
        XCTAssertTrue(running)
        runtime.retryNow()
        XCTAssertEqual(runtime.phase, .running)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runtime.phase, .running)
        XCTAssertEqual(masterCount(ssh), 1)
        await runtime.shutdown()
    }

    // MARK: Service Labels

    func testLabelsAppearWhileAProfileRunsAndOnlyBrowserRulesAreAsked() async throws {
        let ssh = try makeFakeSSHFixture()
        let probe = RecordingProbe(label: ServiceLabel(name: "ComfyUI", isResponding: true))
        let app = try await startApp(ssh: ssh, probe: probe)
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        let board = try XCTUnwrap(app.serviceLabels)
        let store = try XCTUnwrap(app.store)
        let web = ForwardingRule.localTCP(port: 43_320, destinationHost: "127.0.0.1", destinationPort: 8_188)
        let socks = ForwardingRule(kind: .localDynamic, listen: .tcp(bindAddress: "localhost", port: 43_321))
        let reverse = ForwardingRule(kind: .remote, listen: .tcp(bindAddress: "localhost", port: 43_322),
                                     destination: .tcp(host: "localhost", port: 8_188))
        let profile = Tunnel(name: "Mixed", sshHost: "fixture.invalid", rules: [web, socks, reverse])
        store.add(profile)
        XCTAssertTrue(probe.requested.isEmpty, "A stopped profile is not asked")

        store.start(profile)
        let labelled = await waitUntil { board.labels[web.id] == probe.label }
        XCTAssertTrue(labelled)
        XCTAssertEqual(probe.requested, [URL(string: "http://localhost:43320/")!])
        XCTAssertEqual(Array(board.labels.keys), [web.id])

        store.stop(profile)
        XCTAssertTrue(board.labels.isEmpty, "Labels go as soon as the profile stops running")
        XCTAssertNil(app.errorMessage)
    }

    func testAPortThatDoesNotAnswerShowsNoResponseWithoutAnAlert() async throws {
        let probe = RecordingProbe(label: ServiceLabel(name: nil, isResponding: false))
        let (app, store) = try await startPreviewApp(probe: probe)
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        let board = try XCTUnwrap(app.serviceLabels)
        let profile = makeProfile(port: 43_323)
        store.add(profile)
        store.setPreviewPhase(.running, for: profile)
        let labelled = await waitUntil { board.labels[profile.rules[0].id] != nil }
        XCTAssertTrue(labelled)
        XCTAssertEqual(board.labels[profile.rules[0].id]?.caption, "no response")
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.runtime.status("services")?.isActive, true)
    }

    func testWithThePluginOffNothingIsAsked() async throws {
        let probe = RecordingProbe(label: ServiceLabel(name: "Jupyter", isResponding: true))
        let (app, store) = try await startPreviewApp(probe: probe)
        let profile = makeProfile(port: 43_324)
        store.add(profile)
        store.setPreviewPhase(.running, for: profile)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(probe.requested.isEmpty)
        XCTAssertNil(app.serviceLabels)
        XCTAssertNil(app.runtime.status("services"))
    }

    func testAResultThatArrivesAfterTheProfileStoppedIsDropped() async throws {
        let probe = GatedProbe()
        let (app, store) = try await startPreviewApp(probe: probe)
        addTeardownBlock { probe.open() }
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        let board = try XCTUnwrap(app.serviceLabels)
        let profile = makeProfile(port: 43_325)
        store.add(profile)
        store.setPreviewPhase(.running, for: profile)
        let asked = await waitUntil { probe.inFlight == 1 }
        XCTAssertTrue(asked)

        store.setPreviewPhase(.stopped, for: profile)
        probe.open()
        let answered = await waitUntil { probe.inFlight == 0 }
        XCTAssertTrue(answered)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(board.labels.isEmpty)
        XCTAssertEqual(app.runtime.resources("services"), 1, "Only the store observation is still owned")
    }

    func testARuleBoundToAnotherAddressIsNeverAskedOrLabelled() async throws {
        let probe = RecordingProbe(label: ServiceLabel(name: "Jupyter", isResponding: true))
        let (app, store) = try await startPreviewApp(probe: probe)
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        let board = try XCTUnwrap(app.serviceLabels)
        let loopback = ForwardingRule.localTCP(port: 43_340, destinationHost: "127.0.0.1", destinationPort: 80)
        let elsewhere = ForwardingRule(kind: .local, listen: .tcp(bindAddress: "192.0.2.10", port: 43_341),
                                       destination: .tcp(host: "127.0.0.1", port: 80))
        let profile = Tunnel(name: "Two addresses", sshHost: "fixture.invalid", rules: [loopback, elsewhere])
        store.add(profile)
        store.setPreviewPhase(.running, for: profile)
        let labelled = await waitUntil { board.labels[loopback.id] != nil }
        XCTAssertTrue(labelled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.requested, [URL(string: "http://localhost:43340/")!])
        XCTAssertNil(board.labels[elsewhere.id], "A rule that is not asked shows nothing, not \"no response\"")
    }

    func testChangingARunningProfilesRulesDropsItsOldLabelsAndAsksTheNewRule() async throws {
        let probe = RecordingProbe(label: ServiceLabel(name: "Jupyter", isResponding: true))
        let (app, store) = try await startPreviewApp(probe: probe)
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        let board = try XCTUnwrap(app.serviceLabels)
        var profile = makeProfile(port: 43_342)
        let first = profile.rules[0].id
        store.add(profile)
        store.setPreviewPhase(.running, for: profile)
        let labelled = await waitUntil { board.labels[first] != nil }
        XCTAssertTrue(labelled)

        let replacement = ForwardingRule.localTCP(port: 43_343, destinationHost: "127.0.0.1", destinationPort: 80)
        profile.rules = [replacement]
        store.update(profile)
        store.setPreviewPhase(.running, for: profile)
        let relabelled = await waitUntil { board.labels[replacement.id] != nil }
        XCTAssertTrue(relabelled)
        XCTAssertNil(board.labels[first])
        XCTAssertEqual(probe.requested.last, URL(string: "http://localhost:43343/")!)
    }

    func testAtMostFourProbesRunAtOnce() async throws {
        let probe = GatedProbe()
        let (app, store) = try await startPreviewApp(probe: probe)
        addTeardownBlock { probe.open() }
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        let board = try XCTUnwrap(app.serviceLabels)
        let profiles = (0..<6).map { makeProfile("Web \($0)", port: 43_330 + $0) }
        for profile in profiles {
            store.add(profile)
            store.setPreviewPhase(.running, for: profile)
        }
        let saturated = await waitUntil { probe.inFlight == 4 }
        XCTAssertTrue(saturated)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.inFlight, 4)

        probe.open()
        let labelled = await waitUntil { board.labels.count == 6 }
        XCTAssertTrue(labelled)
        XCTAssertEqual(probe.mostInFlight, 4)
        XCTAssertEqual(Set(probe.requested).count, 6)
    }

    func testRecognitionNamesKnownProductsThenTheTitleThenNothing() {
        let html = ["content-type": "text/html; charset=utf-8"]
        let longTitle = String(repeating: "Dashboard ", count: 6)
        let rows: [(page: String, status: Int, headers: [String: String], name: String?)] = [
            ("<html><head><title>ComfyUI</title></head></html>", 200, html, "ComfyUI"),
            ("<title>JupyterLab</title>", 200, html, "Jupyter"),
            (#"<title>Home</title><script id="jupyter-config-data" type="application/json">{}</script>"#, 200, html, "Jupyter"),
            ("<title>TensorBoard</title><tb-webapp></tb-webapp>", 200, html, "TensorBoard"),
            ("<title>Stable Diffusion</title><script>window.gradio_config = {};</script>", 200, html, "Stable Diffusion WebUI"),
            ("<title>Open WebUI</title>", 200, html, "Open WebUI"),
            ("<title>Image Demo</title><gradio-app></gradio-app>", 200, html, "Gradio"),
            ("<TITLE>\n  Grafana\t  Home \n</TITLE>", 200, html, "Grafana Home"),
            ("<title>\(longTitle)</title>", 200, [:], String(longTitle.prefix(40))),
            ("<title>Not Found</title>", 404, html, "Not Found"),
            ("<title>ComfyUI</title>", 302, html, nil),
            (#"{"title": "<title>Service</title>"}"#, 200, ["content-type": "application/json"], nil),
            ("<html><body>No title here</body></html>", 200, html, nil),
            ("<title>   </title>", 200, html, nil),
            ("<title>Safe\u{202E}evil\u{0007} name\u{200B}</title>", 200, html, "Safeevil name")
        ]
        for row in rows {
            let label = ServiceLabel.recognizing(status: row.status, headers: row.headers, body: Data(row.page.utf8))
            XCTAssertEqual(label, ServiceLabel(name: row.name, isResponding: true), row.page)
        }
        XCTAssertEqual(ServiceLabel(name: nil, isResponding: false).caption, "no response")
        XCTAssertEqual(ServiceLabel(name: nil, isResponding: true).caption, "responding")
        XCTAssertEqual(ServiceLabel(name: "Jupyter", isResponding: true).caption, "Jupyter")
    }

    // MARK: HTTP probe

    func testTheHTTPProbeAsksOnlyLoopbackHostsAndKeepsNothing() async throws {
        let server = try await ProbeHTTPServer()
        defer { server.stop() }
        server.serve("/", with: ProbeHTTPServer.response("200 OK", body: "<title>Fixture</title>"))

        // 127.1 reaches this listener too, so a request would show up below.
        let refused = await HTTPServiceProbe().probe(URL(string: "http://127.1:\(server.port)/")!)
        XCTAssertEqual(refused, ServiceLabel(name: nil, isResponding: false))
        XCTAssertTrue(server.requests.isEmpty)
        let answered = await HTTPServiceProbe().probe(URL(string: "http://127.0.0.1:\(server.port)/")!)
        XCTAssertEqual(answered, ServiceLabel(name: "Fixture", isResponding: true))
        XCTAssertEqual(server.paths, ["/"])

        let accepted = ["http://127.0.0.1:1/", "http://localhost:1/", "http://LOCALHOST/", "http://[::1]:8080/"]
        for text in accepted {
            XCTAssertTrue(HTTPServiceProbe.isLoopback(URL(string: text)!), text)
        }
        // HTTPS is refused as well: the probe never evaluates a certificate.
        let refusedURLs = ["http://127.1/", "http://10.0.0.1/", "http://example.com/", "http://localhost.example.com/",
                           "https://localhost/", "https://127.0.0.1:8443/", "ftp://localhost/", "file:///tmp/index.html"]
        for text in refusedURLs {
            XCTAssertFalse(HTTPServiceProbe.isLoopback(URL(string: text)!), text)
        }

        let configuration = HTTPServiceProbe.configuration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 3)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 3)
    }

    func testTheHTTPProbeReportsAClosedPortAsNotResponding() async throws {
        let server = try await ProbeHTTPServer()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        let label = await HTTPServiceProbe().probe(URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual(label, ServiceLabel(name: nil, isResponding: false))
    }

    func testTheHTTPProbeFollowsRedirectsOnlyWithinTheSameHostAndPortAndAtMostThreeTimes() async throws {
        let server = try await ProbeHTTPServer()
        defer { server.stop() }
        let origin = "http://127.0.0.1:\(server.port)"
        server.serve("/same", with: ProbeHTTPServer.response("302 Found", headers: ["Location: /titled"]))
        server.serve("/titled", with: ProbeHTTPServer.response("200 OK", body: "<title>Fixture</title>"))
        server.serve("/away", with: ProbeHTTPServer.response("302 Found", headers: ["Location: http://localhost:\(server.port)/titled"]))
        for step in 0..<4 {
            server.serve("/r\(step)", with: ProbeHTTPServer.response("302 Found", headers: ["Location: /r\(step + 1)"]))
        }
        server.serve("/r4", with: ProbeHTTPServer.response("200 OK", body: "<title>Too Far</title>"))

        let followed = await HTTPServiceProbe().probe(URL(string: "\(origin)/same")!)
        XCTAssertEqual(followed, ServiceLabel(name: "Fixture", isResponding: true))
        XCTAssertEqual(server.paths, ["/same", "/titled"])

        let other = await HTTPServiceProbe().probe(URL(string: "\(origin)/away")!)
        XCTAssertEqual(other, ServiceLabel(name: nil, isResponding: true), "The redirect itself is the answer")
        XCTAssertEqual(server.paths, ["/same", "/titled", "/away"], "Another host is never asked")

        let chain = await HTTPServiceProbe().probe(URL(string: "\(origin)/r0")!)
        XCTAssertEqual(chain, ServiceLabel(name: nil, isResponding: true))
        XCTAssertEqual(Array(server.paths.dropFirst(3)), ["/r0", "/r1", "/r2", "/r3"])
    }

    func testARedirectIsFollowedOnlyAsThePlainRequestTheProbeBuildsItself() async throws {
        let server = try await ProbeHTTPServer()
        defer { server.stop() }
        let port = server.port
        server.serve("/titled", with: ProbeHTTPServer.response("200 OK", body: "<title>Fixture</title>"))
        server.serve("/secure", with: ProbeHTTPServer.response("302 Found", headers: ["Location: https://127.0.0.1:\(port)/titled"]))
        server.serve("/ftp", with: ProbeHTTPServer.response("302 Found", headers: ["Location: ftp://127.0.0.1:\(port)/titled"]))
        server.serve("/port", with: ProbeHTTPServer.response("302 Found", headers: ["Location: http://127.0.0.1:\(port &+ 1)/titled"]))
        server.serve("/named", with: ProbeHTTPServer.response("302 Found",
                                                              headers: ["Location: http://user:secret@127.0.0.1:\(port)/titled"]))

        for path in ["/secure", "/ftp", "/port"] {
            let label = await HTTPServiceProbe().probe(URL(string: "http://127.0.0.1:\(port)\(path)")!)
            XCTAssertEqual(label, ServiceLabel(name: nil, isResponding: true), path)
        }
        XCTAssertEqual(server.paths, ["/secure", "/ftp", "/port"], "None of those redirects was followed")

        let named = await HTTPServiceProbe().probe(URL(string: "http://127.0.0.1:\(port)/named")!)
        XCTAssertEqual(named, ServiceLabel(name: "Fixture", isResponding: true))
        let followed = try XCTUnwrap(server.requests.last)
        XCTAssertTrue(followed.hasPrefix("GET /titled "), followed)
        XCTAssertFalse(followed.lowercased().contains("\r\nauthorization:"), "The name and password in the redirect were dropped")
    }

    func testTheHTTPProbeSendsOnlyItsFixedHeaders() async throws {
        let server = try await ProbeHTTPServer()
        defer { server.stop() }
        server.serve("/first", with: ProbeHTTPServer.response("302 Found", headers: ["Location: /second"]))
        server.serve("/second", with: ProbeHTTPServer.response("200 OK", body: "<title>Fixture</title>"))
        _ = await HTTPServiceProbe().probe(URL(string: "http://127.0.0.1:\(server.port)/first")!)
        XCTAssertEqual(server.paths, ["/first", "/second"])

        // What the probe sets, plus transport headers the system adds that say nothing about this Mac.
        let allowed: Set<String> = ["host", "user-agent", "accept", "accept-language", "accept-encoding", "connection",
                                    "cache-control", "pragma"]
        for request in server.requests {
            var headers: [String: String] = [:]
            for line in request.components(separatedBy: "\r\n").dropFirst() where line.contains(":") {
                let parts = line.split(separator: ":", maxSplits: 1)
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            XCTAssertTrue(Set(headers.keys).isSubset(of: allowed), "Unexpected headers in \(headers.keys.sorted())")
            XCTAssertEqual(headers["user-agent"], "Mozilla/5.0")
            XCTAssertEqual(headers["accept"], "text/html,*/*;q=0.8")
            XCTAssertEqual(headers["accept-language"], "en")
            let lowercased = request.lowercased()
            for word in ["relaybar", "cfnetwork", "darwin", "xctest"] {
                XCTAssertFalse(lowercased.contains(word), "The request names \(word)")
            }
        }
    }

    func testTheHTTPProbeStopsReadingAt64KiBWithoutWaitingForTheRest() async throws {
        let server = try await ProbeHTTPServer()
        defer { server.stop() }
        // The server promises ten megabytes, sends 70,000 bytes and then keeps the connection open.
        let head = ["HTTP/1.1 200 OK", "Content-Type: text/html", "Content-Length: 10000000"].joined(separator: "\r\n") + "\r\n\r\n"
        server.serve("/endless", with: Data((head + String(repeating: "a", count: 70_000)).utf8), keepingOpen: true)
        let clock = ContinuousClock()
        let started = clock.now
        let fetched = await HTTPServiceProbe().fetch(URL(string: "http://127.0.0.1:\(server.port)/endless")!)
        let elapsed = clock.now - started
        XCTAssertEqual(fetched?.body.count, 65_536)
        XCTAssertLessThan(elapsed, .seconds(2), "The probe returned at the limit instead of waiting for the body or the timeout")
    }

    func testRetryWaitingNowDoesNothingAfterAdmissionCloses() async throws {
        let ssh = try makeFakeSSHFixture(overrides: ["RELAYBAR_FAKE_SSH_FAIL_MASTER": "1"])
        let app = try await startApp(ssh: ssh, maxRetryAttempts: 3)
        let store = try XCTUnwrap(app.store)
        let profile = makeProfile(port: 43_350)
        store.add(profile)
        store.start(profile)
        let waiting = await waitUntil { self.attempt(store.phase(for: profile)) == 1 }
        XCTAssertTrue(waiting)
        let launches = masterCount(ssh)

        store.closeAdmission()
        store.retryWaitingNow()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(masterCount(ssh), launches, "A closed store launches nothing")
    }

    func testSwitchingServiceLabelsOffWhileProbesAreHeldAndQueuedLeavesNothingBehind() async throws {
        let probe = GatedProbe()
        let (app, store) = try await startPreviewApp(probe: probe)
        addTeardownBlock { probe.open() }
        try await app.setPlugin(RelayPlugins.services, enabled: true)
        let board = try XCTUnwrap(app.serviceLabels)
        let profiles = (0..<6).map { makeProfile("Held \($0)", port: 43_360 + $0) }
        for profile in profiles {
            store.add(profile)
            store.setPreviewPhase(.running, for: profile)
        }
        let saturated = await waitUntil { probe.inFlight == 4 }
        XCTAssertTrue(saturated)

        // Four probes are in flight and two wait for a place. The plugin goes off; the held probes
        // answer afterwards. Unloading must finish, and no late answer may be recorded.
        let unloading = Task { try await app.setPlugin(RelayPlugins.services, enabled: false) }
        try await Task.sleep(for: .milliseconds(100))
        probe.open()
        try await unloading.value
        XCTAssertNil(app.serviceLabels)
        XCTAssertNil(app.runtime.status("services"))
        XCTAssertTrue(board.labels.isEmpty, "An answer that arrived after the plugin went off was dropped")
        XCTAssertEqual(probe.requested.count, 4, "The two queued probes never started")
    }

    func testTheHTTPProbeReadsAtMost64KiB() async throws {
        let server = try await ProbeHTTPServer()
        defer { server.stop() }
        let page = String(repeating: "a", count: 70_000) + "<title>Late</title>"
        server.serve("/big", with: ProbeHTTPServer.response("200 OK", body: page))
        let url = URL(string: "http://127.0.0.1:\(server.port)/big")!

        let fetched = await HTTPServiceProbe().fetch(url)
        XCTAssertEqual(fetched?.body.count, 65_536)
        let label = await HTTPServiceProbe().probe(url)
        XCTAssertEqual(label, ServiceLabel(name: nil, isResponding: true), "The title past the limit was never read")
    }

    func testTheHTTPProbeSendsNoCookieAndNoCredentials() async throws {
        let server = try await ProbeHTTPServer()
        defer { server.stop() }
        server.serve("/set", with: ProbeHTTPServer.response("302 Found", headers: ["Location: /check", "Set-Cookie: session=secret; Path=/"]))
        server.serve("/check", with: ProbeHTTPServer.response("200 OK", body: "<title>Checked</title>"))
        server.serve("/auth", with: ProbeHTTPServer.response("401 Unauthorized", headers: [#"WWW-Authenticate: Basic realm="fixture""#],
                                                             body: "<title>Locked</title>"))

        let checked = await HTTPServiceProbe().probe(URL(string: "http://127.0.0.1:\(server.port)/set")!)
        XCTAssertEqual(checked, ServiceLabel(name: "Checked", isResponding: true))
        let locked = await HTTPServiceProbe().probe(URL(string: "http://user:secret@127.0.0.1:\(server.port)/auth")!)
        XCTAssertEqual(locked, ServiceLabel(name: nil, isResponding: true), "Asking for credentials is an answer")

        XCTAssertEqual(server.paths, ["/set", "/check", "/auth"], "The challenge was not answered and the GET not repeated")
        for request in server.requests {
            let lowercased = request.lowercased()
            XCTAssertFalse(lowercased.contains("\r\ncookie:"), request)
            XCTAssertFalse(lowercased.contains("\r\nauthorization:"), request)
        }
    }

    // MARK: Open in Frame

    func testOpenInFrameIsInTheCatalogAndIsOnByDefaultOnlyWhenFrameIsInstalled() async throws {
        XCTAssertEqual(RelayPlugins.frame(installed: true).features, ["frame.host", "remote.files/open-in-frame"])
        for installed in [true, false] {
            let (defaults, suite) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = makeApp(defaults: defaults, frameInstalled: installed)
            XCTAssertEqual(app.plugins.map(\.id), ["recovery", "services", "frame", "paper"])
            XCTAssertEqual(app.plugins.first { $0.id == "frame" }, app.framePlugin)
            XCTAssertEqual(app.framePlugin.isOnByDefault, installed)
            await app.start()
            try await app.setRemoteFilesOpen(true)
            XCTAssertEqual(app.isPluginEnabled(app.framePlugin), installed)
            XCTAssertEqual(app.runtime.status("remote.files/open-in-frame") != nil, installed)
            await app.stop()
        }
    }

    func testAnExplicitChoiceBeatsWhetherFrameIsInstalledInBothDirections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RelayFrameChoice-\(UUID())")
        let (defaults, suite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("preferences.json")
        /// Launches with Frame installed or not, optionally switches the plugin, and says whether it ended up on.
        func launch(installed: Bool, choosing choice: Bool? = nil) async throws -> Bool {
            let app = makeApp(defaults: defaults, preferencesURL: url, frameInstalled: installed)
            await app.start()
            XCTAssertNil(app.errorMessage)
            if let choice { try await app.setPlugin(app.framePlugin, enabled: choice) }
            let enabled = app.isPluginEnabled(app.framePlugin)
            await app.stop()
            return enabled
        }
        let steps: [(installed: Bool, choice: Bool?, expected: Bool, note: String)] = [
            (true, nil, true, "never chosen, Frame installed"),
            (false, nil, false, "never chosen, Frame missing"),
            (true, false, false, "off by hand"),
            (true, nil, false, "an explicit off beats Frame being installed"),
            (false, true, true, "on by hand"),
            (false, nil, true, "an explicit on beats Frame being missing"),
            (true, true, true, "on by hand, equal to today's default"),
            (false, nil, true, "that choice was kept although it matched the default"),
            (false, false, false, "off by hand, equal to today's default"),
            (true, nil, false, "that choice was kept as well")
        ]
        for step in steps {
            let enabled = try await launch(installed: step.installed, choosing: step.choice)
            XCTAssertEqual(enabled, step.expected, step.note)
        }
        let saved = PreferenceStore(url: url, initial: RelayBarPreferences()) { try $0.validate() }
        try saved.load()
        XCTAssertEqual(saved.value.plugins.overrides, ["frame": false])
    }

    func testWithOpenInFrameOffNothingListensAndTheWindowHasNoFrameViewer() async throws {
        let (app, socket) = try await startBridgeApp(frameInstalled: false)
        try await app.setRemoteFilesOpen(true)
        let model = try XCTUnwrap(app.runtime.service(RelayServices.RemoteFiles.self))
        XCTAssertFalse(app.isPluginEnabled(app.framePlugin))
        XCTAssertNil(app.runtime.status("frame.host"))
        XCTAssertNil(app.runtime.status("remote.files/open-in-frame"))
        XCTAssertNil(app.frameHost)
        XCTAssertNil(model.frameViewer, "The window shows no Open in Frame")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: socket.deletingLastPathComponent().path), [],
                       "No socket and no transfer folder were made")
        XCTAssertFalse(accepts(socket))
    }

    func testSwitchingOpenInFrameWithTheWindowOpenStartsAndStopsTheBridgeAndTheButtons() async throws {
        let (app, socket) = try await startBridgeApp(frameInstalled: false)
        try await app.setRemoteFilesOpen(true)
        let model = try XCTUnwrap(app.runtime.service(RelayServices.RemoteFiles.self))
        let window = app.windows
        let generations = ["tunnels", "remote.files"].map { app.runtime.status($0)?.generation }
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        try await app.setPlugin(app.framePlugin, enabled: true)
        XCTAssertEqual(app.runtime.status("frame.host")?.isActive, true)
        XCTAssertEqual(app.runtime.status("remote.files/open-in-frame")?.isActive, true)
        XCTAssertNotNil(app.frameHost)
        XCTAssertNotNil(model.frameViewer)
        XCTAssertGreaterThan(changes, 0, "The open window is told, so its Open in Frame buttons appear")
        XCTAssertTrue(accepts(socket), "The bridge is listening")

        changes = 0
        try await app.setPlugin(app.framePlugin, enabled: false)
        XCTAssertNil(app.runtime.status("frame.host"))
        XCTAssertNil(app.runtime.status("remote.files/open-in-frame"))
        XCTAssertNil(app.frameHost)
        XCTAssertNil(model.frameViewer)
        XCTAssertGreaterThan(changes, 0, "The open window is told, so its Open in Frame buttons go away")
        XCTAssertFalse(accepts(socket), "Nothing is listening")

        try await app.setPlugin(app.framePlugin, enabled: true)
        XCTAssertNotNil(app.frameHost)
        XCTAssertNotNil(model.frameViewer)
        XCTAssertTrue(accepts(socket))
        XCTAssertTrue(app.windows === window, "The window was never replaced")
        XCTAssertEqual(["tunnels", "remote.files"].map { app.runtime.status($0)?.generation }, generations)
    }

    // MARK: Fixtures

    private func makeApp(defaults: UserDefaults, preferencesURL: URL? = nil,
                         makeTunnels: (@MainActor () -> TunnelStore)? = nil,
                         events: any RecoveryEvents = ManualRecoveryEvents(), debounce: Duration = .milliseconds(50),
                         probe: any ServiceProbing = RecordingProbe(label: ServiceLabel(name: nil, isResponding: true)),
                         frameInstalled: Bool = false, startsBridge: Bool = false,
                         bridgeRoot: @escaping () throws -> URL = { throw CompositionError("No bridge in this test.") })
        -> RelayBarComposition {
        RelayBarComposition(defaults: defaults, preferencesURL: preferencesURL, startsBridge: startsBridge, showsWindows: false,
            makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
            makeTunnels: makeTunnels ?? { TunnelStore(defaults: defaults, persistsRetryLimit: false) },
            makeFileService: { IdleFileService() },
            makeUpdates: { _ in UnavailableUpdateService() }, loginService: LoginItemServiceSpy(status: .notRegistered),
            recoveryEvents: events, recoveryDebounce: debounce, serviceProbe: probe,
            frameInstalled: frameInstalled, bridgeRoot: bridgeRoot)
    }

    /// A started app whose Frame bridge, whenever it runs, listens in a folder of this test's own.
    private func startBridgeApp(frameInstalled: Bool) async throws -> (RelayBarComposition, URL) {
        let (defaults, suite) = makeIsolatedDefaults()
        // Short, because a socket's path is limited to 104 bytes.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rbf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = makeApp(defaults: defaults, frameInstalled: frameInstalled, startsBridge: true, bridgeRoot: { root })
        addTeardownBlock {
            await app.stop()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await app.start()
        XCTAssertNil(app.errorMessage)
        return (app, root.appendingPathComponent("viewer.sock"))
    }

    /// Whether anything accepts a connection on the Unix socket at `url`.
    private func accepts(_ url: URL) -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    /// A started app whose store runs the fake SSH fixture, with a 60-second backoff. The retry limit is
    /// imported into the preference document, which the composed app applies to the store.
    private func startApp(ssh: FakeSSHFixture, maxRetryAttempts: Int = 2, events: any RecoveryEvents = ManualRecoveryEvents(),
                          debounce: Duration = .milliseconds(50),
                          probe: any ServiceProbing = RecordingProbe(label: ServiceLabel(name: nil, isResponding: true)))
        async throws -> RelayBarComposition {
        ssh.defaults.set(maxRetryAttempts, forKey: "sshRetryLimit.v1")
        let app = makeApp(defaults: ssh.defaults, makeTunnels: {
            self.makeFakeStore(fixture: ssh, maxRetryAttempts: maxRetryAttempts, retryDelay: 60)
        }, events: events, debounce: debounce, probe: probe)
        addTeardownBlock {
            await app.stop()
            ssh.cleanup()
        }
        await app.start()
        XCTAssertNil(app.errorMessage)
        return app
    }

    /// A started app whose profiles never launch SSH; tests set their phases directly.
    private func startPreviewApp(probe: any ServiceProbing) async throws -> (RelayBarComposition, TunnelStore) {
        let (defaults, suite) = makeIsolatedDefaults()
        let app = makeApp(defaults: defaults, probe: probe)
        addTeardownBlock {
            await app.stop()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        await app.start()
        return (app, try XCTUnwrap(app.store))
    }

    private func makeProfile(_ name: String = "Web", port: Int) -> Tunnel {
        Tunnel(name: name, localPort: port, destinationHost: "127.0.0.1", destinationPort: 80, sshHost: "fixture.invalid")
    }

    private func attempt(_ phase: TunnelPhase) -> Int? {
        guard case .retrying(let attempt, _, _, _) = phase else { return nil }
        return attempt
    }

    private func isFailed(_ phase: TunnelPhase) -> Bool {
        guard case .failed = phase else { return false }
        return true
    }

    private func masterCount(_ ssh: FakeSSHFixture) -> Int {
        masterInvocationCount((try? String(contentsOf: ssh.logURL, encoding: .utf8)) ?? "")
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// A file service for a window that is opened but never browsed.
private actor IdleFileService: RemoteFileServing {
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] { [] }
    func download(server: RemoteServer, entry: RemoteFileEntry, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {}
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL { throw CancellationError() }
}

/// Hands Reconnect on Wake streams the test pushes into, and counts the streams that started and ended.
private final class ManualRecoveryEvents: RecoveryEvents {
    private struct State {
        var streams: [AsyncStream<Void>.Continuation] = []
        var ended = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var started: Int { state.withLock { $0.streams.count } }
    var ended: Int { state.withLock { $0.ended } }

    func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.onTermination = { [state] _ in
                state.withLock { $0.ended += 1 }
            }
            state.withLock { $0.streams.append(continuation) }
        }
    }

    func send() {
        let streams = state.withLock { $0.streams }
        for stream in streams {
            stream.yield()
        }
    }
}

/// Answers every probe with one label and records the URLs it was asked about.
private final class RecordingProbe: ServiceProbing {
    let label: ServiceLabel
    private let asked = OSAllocatedUnfairLock(initialState: [URL]())

    init(label: ServiceLabel) {
        self.label = label
    }

    var requested: [URL] { asked.withLock { $0 } }

    func probe(_ url: URL) async -> ServiceLabel {
        asked.withLock { $0.append(url) }
        return label
    }
}

/// Holds every probe until it is opened, and records how many were in flight at once.
private final class GatedProbe: ServiceProbing {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var inFlight = 0
        var mostInFlight = 0
        var requested: [URL] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var inFlight: Int { state.withLock { $0.inFlight } }
    var mostInFlight: Int { state.withLock { $0.mostInFlight } }
    var requested: [URL] { state.withLock { $0.requested } }

    func probe(_ url: URL) async -> ServiceLabel {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { current in
                current.requested.append(url)
                current.inFlight += 1
                current.mostInFlight = max(current.mostInFlight, current.inFlight)
                if !current.isOpen {
                    current.waiting.append(continuation)
                }
                return current.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
        state.withLock { $0.inFlight -= 1 }
        return ServiceLabel(name: "Gated", isResponding: true)
    }

    func open() {
        let waiting = state.withLock { current in
            current.isOpen = true
            let waiting = current.waiting
            current.waiting = []
            return waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// A loopback HTTP server that answers each path with a raw response and records every request it reads.
private final class ProbeHTTPServer: @unchecked Sendable {
    private struct State {
        var responses: [String: Data] = [:]
        var requests: [String] = []
        var keptOpen: Set<String> = []
    }
    private let listener: NWListener
    private let state = OSAllocatedUnfairLock(initialState: State())
    private(set) var port: UInt16 = 0

    var requests: [String] { state.withLock { $0.requests } }
    var paths: [String] { requests.map { Self.path(of: $0) } }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let state = self.state
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let response = ProbeHTTPServer.respond(to: request, in: state)
                let staysOpen = state.withLock { $0.keptOpen.contains(ProbeHTTPServer.path(of: request)) }
                connection.send(content: response, completion: .contentProcessed { _ in
                    if !staysOpen {
                        connection.cancel()
                    }
                })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// A complete response that closes its connection.
    static func response(_ status: String, headers: [String] = [], body: String = "") -> Data {
        let lines = ["HTTP/1.1 \(status)", "Content-Type: text/html", "Content-Length: \(body.utf8.count)", "Connection: close"]
            + headers
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    /// `keepingOpen` leaves the connection open after the response's bytes are sent.
    func serve(_ path: String, with response: Data, keepingOpen: Bool = false) {
        state.withLock { current in
            current.responses[path] = response
            if keepingOpen {
                current.keptOpen.insert(path)
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private static func respond(to request: String, in state: OSAllocatedUnfairLock<State>) -> Data {
        state.withLock { current in
            current.requests.append(request)
            return current.responses[Self.path(of: request)] ?? Self.response("404 Not Found")
        }
    }

    private static func path(of request: String) -> String {
        request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
    }
}

private extension NSColor {
    func usingColorSpace(_ space: NSColorSpace, in appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance { result = usingColorSpace(space) ?? self }
        return result
    }
}
