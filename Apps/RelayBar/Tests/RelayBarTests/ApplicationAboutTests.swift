import Combine
import Foundation
import XCTest
@testable import RelayBar

@MainActor
private final class ExternalLinkOpenerSpy: ExternalLinkOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

@MainActor
private final class PasteboardWriterSpy: PasteboardWriting {
    private(set) var strings: [String] = []
    var succeeds = true

    func write(_ string: String) -> Bool {
        strings.append(string)
        return succeeds
    }
}

@MainActor
private final class AccessibilityAnnouncerSpy: AccessibilityAnnouncing {
    private(set) var messages: [String] = []

    func announce(_ message: String) {
        messages.append(message)
    }
}

@MainActor
final class ApplicationAboutTests: XCTestCase {
    func testMetadataUsesVersionAndBuildFromBundleDictionary() {
        let metadata = ApplicationMetadata(
            infoDictionary: [
                "CFBundleName": "RelayBar",
                "CFBundleShortVersionString": "1.3.0",
                "CFBundleVersion": "6"
            ]
        )

        XCTAssertEqual(metadata.displayText, "RelayBar 1.3.0 (6)")
        XCTAssertEqual(
            metadata.accessibilityLabel,
            "RelayBar version 1.3.0, build 6"
        )
    }

    func testMetadataHasTruthfulFallbacksForMissingOrMalformedValues() {
        XCTAssertEqual(
            ApplicationMetadata(infoDictionary: [:]).displayText,
            "RelayBar version unavailable"
        )
        XCTAssertEqual(
            ApplicationMetadata(
                infoDictionary: [
                    "CFBundleName": "  ",
                    "CFBundleShortVersionString": "2.0",
                    "CFBundleVersion": 9
                ]
            ).displayText,
            "RelayBar 2.0"
        )
        XCTAssertEqual(
            ApplicationMetadata(
                infoDictionary: ["CFBundleVersion": "9"]
            ).displayText,
            "RelayBar build 9"
        )
    }

    func testProjectActionsOpenEachCanonicalURLOnce() {
        let opener = ExternalLinkOpenerSpy()
        let model = ApplicationAboutModel(linkOpener: opener)

        model.openWebsite()
        model.openRepository()

        XCTAssertEqual(
            opener.openedURLs,
            [RelayBarProjectLink.website, RelayBarProjectLink.repository]
        )
    }

    func testCopyWritesDisplayTextAndAnnouncesSuccess() async {
        let pasteboard = PasteboardWriterSpy()
        let announcer = AccessibilityAnnouncerSpy()
        let model = ApplicationAboutModel(
            metadata: ApplicationMetadata(
                infoDictionary: [
                    "CFBundleName": "RelayBar",
                    "CFBundleShortVersionString": "1.3.0",
                    "CFBundleVersion": "6"
                ]
            ),
            pasteboardWriter: pasteboard,
            announcer: announcer,
            confirmationDuration: .milliseconds(10)
        )
        let confirmationCleared = expectation(
            description: "Copy confirmation clears"
        )
        let cancellable = model.$didCopyVersion
            .dropFirst()
            .filter { !$0 }
            .first()
            .sink { _ in confirmationCleared.fulfill() }

        model.copyVersion()

        XCTAssertEqual(pasteboard.strings, ["RelayBar 1.3.0 (6)"])
        XCTAssertEqual(announcer.messages, ["Copied"])
        XCTAssertTrue(model.didCopyVersion)

        await fulfillment(of: [confirmationCleared], timeout: 1)
        cancellable.cancel()
        XCTAssertFalse(model.didCopyVersion)
    }

    func testFailedCopyDoesNotConfirmOrAnnounce() {
        let pasteboard = PasteboardWriterSpy()
        pasteboard.succeeds = false
        let announcer = AccessibilityAnnouncerSpy()
        let model = ApplicationAboutModel(
            pasteboardWriter: pasteboard,
            announcer: announcer
        )

        model.copyVersion()

        XCTAssertFalse(model.didCopyVersion)
        XCTAssertTrue(announcer.messages.isEmpty)
    }

    func testPopoverContentWidthSubtractsBalancedInsets() {
        XCTAssertEqual(
            RelayBarPopoverLayout.contentWidth(for: 380),
            348
        )
        XCTAssertEqual(
            RelayBarPopoverLayout.contentWidth(
                for: 24,
                horizontalInset: 16
            ),
            0
        )
    }
}
