import SwiftUI
import XCTest
@testable import RelayBar

final class RemoteSidebarFocusNavigatorTests: XCTestCase {
    func testArrowsMoveFocusWithoutActivatingAnyLocation() {
        let first = RemoteSidebarFocus.location(UUID())
        let host = RemoteSidebarFocus.host(UUID())
        let last = RemoteSidebarFocus.location(UUID())
        let items = [first, host, last]

        XCTAssertEqual(
            RemoteSidebarFocusNavigator.adjacent(
                to: nil,
                moving: .down,
                within: items
            ),
            first
        )
        XCTAssertEqual(
            RemoteSidebarFocusNavigator.adjacent(
                to: first,
                moving: .down,
                within: items
            ),
            host
        )
        XCTAssertEqual(
            RemoteSidebarFocusNavigator.adjacent(
                to: host,
                moving: .up,
                within: items
            ),
            first
        )
    }

    func testFocusMovementStopsAtVisibleBoundsAndIgnoresHorizontalArrows() {
        let first = RemoteSidebarFocus.location(UUID())
        let last = RemoteSidebarFocus.showAllRecentFolders
        let items = [first, last]

        XCTAssertEqual(
            RemoteSidebarFocusNavigator.adjacent(
                to: first,
                moving: .up,
                within: items
            ),
            first
        )
        XCTAssertEqual(
            RemoteSidebarFocusNavigator.adjacent(
                to: last,
                moving: .down,
                within: items
            ),
            last
        )
        XCTAssertEqual(
            RemoteSidebarFocusNavigator.adjacent(
                to: first,
                moving: .right,
                within: items
            ),
            first
        )
    }
}
