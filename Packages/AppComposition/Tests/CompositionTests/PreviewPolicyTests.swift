import AssetGrouping
import Composition
import PreviewSupport
import XCTest

final class PreviewPolicyTests: XCTestCase {
    func testFileTypesAndImageChoice() {
        XCTAssertEqual(PreviewFileTypes.markdown, ["md", "markdown", "mdown", "mkd"])
        XCTAssertTrue(AssetCompanionNames.isDocument("notes.MKD"))
        XCTAssertEqual(PreviewFileTypes.html, ["html", "htm"])
        XCTAssertEqual(PreviewFileTypes.video, ["mp4", "mov", "m4v"])
        var choices = PluginChoices()
        func images() -> Set<String> {
            PreviewFileTypes.images(extended: choices.isEnabled(PreviewPlugins.moreImages))
        }
        XCTAssertEqual(images(), ["jpeg", "jpg", "png", "bmp", "gif", "heic", "heif", "tif", "tiff", "webp"])
        choices.set(PreviewPlugins.moreImages, enabled: false)
        XCTAssertEqual(images(), ["jpg", "jpeg", "png"])
    }

    func testVersionOneArchiveCompanionsKeepTheirMembership() {
        XCTAssertTrue(AssetCompanionNames.validArchiveMembers(["a.jpg", "a.webp", "a.mkd"]))
        XCTAssertFalse(AssetCompanionNames.validArchiveMembers(["a.jpg", "a.png"]))
        XCTAssertFalse(AssetCompanionNames.validArchiveMembers(["a.jpg", "other/a.webp"]))
    }

    func testCompanionLimitCountsUnicodeScalarsLikeTheRemoteHelper() {
        var remaining = 2
        XCTAssertEqual(PreviewLimits.companionText("e\u{301}!", remaining: &remaining), "e\u{301}")
        XCTAssertEqual(remaining, 0)
    }

    func testPreviewLimits() {
        XCTAssertEqual(PreviewLimits.document, 10 << 20)
        XCTAssertEqual(PreviewLimits.asset, 32 << 20)
        XCTAssertEqual(PreviewLimits.page, 64 << 20)
        XCTAssertEqual(PreviewLimits.requests, 128)
        XCTAssertEqual(PreviewLimits.original, 100 << 20)
        XCTAssertEqual(PreviewLimits.entries, 10_000)
        XCTAssertEqual(PreviewLimits.companions, 32)
        XCTAssertEqual(PreviewLimits.companionBytes, 2 << 20)
        XCTAssertEqual(PreviewLimits.companionCharacters, 256_000)
    }
}
