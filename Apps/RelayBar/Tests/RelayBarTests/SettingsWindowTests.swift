import AppKit
import CompositionFixtures
import XCTest
@testable import RelayBar

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testWindowIsFixedWidthAndAlwaysExactlyAsTallAsItsContent() async throws {
        let (composition, login) = try await startedComposition()
        let controller = RelaySettingsWindowController(composition: composition, about: aboutModel(), windowType: QuietSettingsWindow.self)
        let window = controller.window
        XCTAssertEqual(window.title, "RelayBar Settings")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))

        window.setFrameTopLeftPoint(NSPoint(x: 120, y: 900))
        let top = window.frame.maxY
        let before = try settle(window)
        XCTAssertEqual(before.width, SettingsLayout.width)

        // The approval note adds a line under Launch at Login; the window grows down to fit it.
        login.status = .requiresApproval
        composition.login?.refresh()
        let after = try settle(window)
        XCTAssertGreaterThan(after.height, before.height)
        XCTAssertEqual(after.width, SettingsLayout.width)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "The title bar stays where it was")

        login.status = .enabled
        composition.login?.refresh()
        XCTAssertEqual(try settle(window).height, before.height, accuracy: 0.5)
    }

    func testCommandWAndEscapeCloseTheWindow() async throws {
        let (composition, _) = try await startedComposition()
        let about = aboutModel()
        let controller = RelaySettingsWindowController(composition: composition, about: about, windowType: QuietSettingsWindow.self)
        let window = try XCTUnwrap(controller.window as? QuietSettingsWindow)
        defer { window.orderOut(nil) }

        // Closing clears the copy confirmation, so each check also shows the close went through the delegate.
        let closers: [(String, () throws -> Void)] = [
            ("Command-W", { XCTAssertTrue(window.performKeyEquivalent(with: try self.key("w", code: 13, modifiers: .command))) }),
            ("Escape", { XCTAssertTrue(window.performKeyEquivalent(with: try self.key("\u{1b}", code: 53))) }),
            ("Cancel", { window.cancelOperation(nil) })
        ]
        for (name, close) in closers {
            window.orderInOffscreen()
            about.copyVersion()
            XCTAssertTrue(window.isVisible)
            try close()
            XCTAssertFalse(window.isVisible, name)
            XCTAssertFalse(about.didCopyVersion, name)
        }
        XCTAssertFalse(window.performKeyEquivalent(with: try key("q", code: 12, modifiers: .command)))
    }

    func testTypedRetryLimitReachesTheStoreOnlyWhenCommittedAndIsClamped() async throws {
        let (composition, _) = try await startedComposition()
        let controller = RelaySettingsWindowController(composition: composition, about: aboutModel(), windowType: QuietSettingsWindow.self)
        let window = controller.window
        _ = try settle(window)
        let field = try XCTUnwrap(firstTextField(in: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(field.stringValue, "10")

        for (typed, expected) in [("500", 100), ("500", 100), ("-3", 0), ("4", 4)] {
            let before = composition.store?.maxRetryAttempts
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
            _ = try settle(window)
            XCTAssertEqual(composition.store?.maxRetryAttempts, before, "Typing \(typed) commits nothing yet")

            editor.insertNewline(nil)
            try await waitUntil { composition.store?.maxRetryAttempts == expected }
            _ = try settle(window)
            XCTAssertEqual(field.stringValue, "\(expected)", "Typed \(typed)")
            XCTAssertTrue(window.makeFirstResponder(nil))
        }
        XCTAssertNil(composition.errorMessage)
    }

    func testSettingsIsNotMadeWhenTheAppRunsWithoutWindows() async throws {
        let (composition, _) = try await startedComposition()
        composition.showSettings()
        XCTAssertNil(composition.settingsWindow)
    }

    // MARK: Fixtures

    private func startedComposition() async throws -> (RelayBarComposition, LoginItemServiceSpy) {
        let suite = "RelayBarSettingsWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let login = LoginItemServiceSpy(status: .enabled)
        let composition = RelayBarComposition(
            defaults: defaults, startsBridge: false, showsWindows: false,
            makeCatalog: { RemoteServerCatalog(defaults: defaults, sshConfigURL: URL(fileURLWithPath: "/nonexistent")) },
            makeTunnels: { TunnelStore(defaults: defaults, persistsRetryLimit: false) },
            makeUpdates: { _ in UnavailableUpdateService() },
            loginService: login,
            recoveryEvents: QuietRecoveryEvents(),
            frameInstalled: false
        )
        addTeardownBlock {
            await composition.stop()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        await composition.start()
        XCTAssertNil(composition.errorMessage)
        return (composition, login)
    }

    private func aboutModel() -> ApplicationAboutModel {
        ApplicationAboutModel(
            metadata: ApplicationMetadata(infoDictionary: [
                "CFBundleName": "RelayBar", "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "22"
            ]),
            pasteboardWriter: AcceptingPasteboard(),
            announcer: QuietAnnouncer(),
            confirmationDuration: .seconds(30)
        )
    }

    /// Lets SwiftUI and AppKit finish layout, then checks the window against its content's fitting size.
    private func settle(_ window: NSWindow) throws -> NSSize {
        for _ in 0..<5 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.frame.size.width, content.fittingSize.width, accuracy: 0.5)
        XCTAssertEqual(content.frame.size.height, content.fittingSize.height, accuracy: 0.5)
        return content.frame.size
    }

    private func key(
        _ characters: String,
        code: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out")
    }
}

private struct QuietRecoveryEvents: RecoveryEvents {
    func events() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}

@MainActor
private struct AcceptingPasteboard: PasteboardWriting {
    func write(_ string: String) -> Bool { true }
}

@MainActor
private struct QuietAnnouncer: AccessibilityAnnouncing {
    func announce(_ message: String) {}
}
