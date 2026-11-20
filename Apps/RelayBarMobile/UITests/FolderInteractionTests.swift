import XCTest

@MainActor
final class FolderInteractionTests: XCTestCase {
  func testFindFolderAndRevealHiddenItemsForOneVisit() throws {
    try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Uses the iPad Start page.")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--demo-host"]
    let device = XCUIDevice.shared
    let originalOrientation = device.orientation
    defer { device.orientation = originalOrientation }
    device.orientation = .portrait
    app.launch()

    func findFolder() {
      let field = app.textFields["Find an article, folder or website"]
      XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
      field.tap()
      field.typeText("samples")
      let hit = app.buttons.matching(NSPredicate(
        format: "label CONTAINS %@ AND label CONTAINS %@", "samples", "Return to open")).firstMatch
      XCTAssertTrue(hit.waitForExistence(timeout: 20), app.debugDescription)
      hit.tap()
    }

    findFolder()
    let show = app.buttons["Show 1 hidden item"]
    XCTAssertTrue(show.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertGreaterThanOrEqual(show.frame.height, 44)
    XCTAssertGreaterThanOrEqual(show.frame.width, 44)
    let hiddenFile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ".catalog")).firstMatch
    XCTAssertFalse(hiddenFile.exists)
    show.tap()
    XCTAssertTrue(hiddenFile.waitForExistence(timeout: 10), app.debugDescription)

    device.orientation = .landscapeLeft
    XCTAssertGreaterThan(app.frame.width, app.frame.height)
    let start = app.buttons["Start"]
    // The window rotates before XCTest updates the sidebar button’s hit coordinates.
    let landscapeRow = expectation(for: NSPredicate { _, _ in
      let frame = start.frame
      return frame.width > 200 && frame.height >= 44 && frame.width > frame.height
    }, evaluatedWith: nil)
    wait(for: [landscapeRow], timeout: 10)
    start.tap()
    findFolder()
    XCTAssertTrue(show.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertFalse(hiddenFile.exists)
  }
}
