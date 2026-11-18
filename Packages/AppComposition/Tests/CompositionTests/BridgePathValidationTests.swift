import BridgeProtocol
import XCTest

final class BridgePathValidationTests: XCTestCase {
    /// A slash followed by a combining mark is one `Character`, but the file system still splits the path there.
    func testASlashIsFoundEvenWhenACombiningMarkFollowsIt() {
        let mark = "\u{0301}"
        XCTAssertFalse(FrameBridgeEnvironment.validName("a/\(mark)b"))
        XCTAssertFalse(FrameBridgeEnvironment.validName("/\(mark)"))
        // The only `..` here ends at a slash that a combining mark follows, so a split by Character never sees it.
        XCTAssertFalse(FrameBridgeEnvironment.validPath("/library/../\(mark)outside"))
        XCTAssertFalse(FrameBridgeEnvironment.validPath("/library/./\(mark)file"))
        XCTAssertFalse(FrameBridgeEnvironment.validPath("/library/..\(mark)/../outside"))
        XCTAssertFalse(FrameBridgeEnvironment.validPath("/library/x/\(mark)/../../outside"))
        XCTAssertFalse(FrameBridgeEnvironment.validPath("/library/./file"))
    }

    func testOrdinaryNamesAndPathsStayValid() {
        XCTAssertTrue(FrameBridgeEnvironment.validName("résumé e\u{0301}.md"))
        XCTAssertTrue(FrameBridgeEnvironment.validName("..hidden"))
        XCTAssertTrue(FrameBridgeEnvironment.validPath("/srv/photos/2026/été/a..b.png"))
        XCTAssertTrue(FrameBridgeEnvironment.validPath("/"))
        XCTAssertFalse(FrameBridgeEnvironment.validName(".."))
        XCTAssertFalse(FrameBridgeEnvironment.validPath("relative/path"))
    }
}
