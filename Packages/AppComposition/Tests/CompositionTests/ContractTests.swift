import AssetGrouping
import BridgeProtocol
import CompositionFixtures
import Foundation
import XCTest

final class ContractTests: XCTestCase {
    func testOlderResponsesAreIncompatibleAndOnlyNamedFailuresEndTheSession() throws {
        let older = Data(#"{"version":6,"status":"ready","error":"Open a folder in RelayBar and choose Open in Frame to allow remote viewing."}"#.utf8)
        let response = try JSONDecoder().decode(BridgeResponse.self, from: older)
        XCTAssertThrowsError(try response.checked()) { error in
            XCTAssertEqual((error as? BridgeError)?.sessionFailure, .incompatible)
        }
        XCTAssertThrowsError(try BridgeResponse(error: "File missing.").checked()) { error in
            XCTAssertNil((error as? BridgeError)?.sessionFailure, "A file error leaves the session usable")
        }
        let closing = BridgeResponse(error: "Closing.", sessionFailure: .unavailable)
        let decoded = try JSONDecoder().decode(BridgeResponse.self, from: JSONEncoder().encode(closing))
        XCTAssertEqual(decoded.version, 7)
        XCTAssertThrowsError(try decoded.checked()) { error in
            XCTAssertEqual((error as? BridgeError)?.sessionFailure, .unavailable)
            XCTAssertEqual(error.localizedDescription, "Closing.")
        }
    }

    func testCallsCarryAnIdAndTheRequestPayloadShapeIsStable() throws {
        let payload = Data(#"{"id":4,"request":{"version":7,"operation":"deleteBatch","targets":[{"listingID":"00000000-0000-0000-0000-000000000001","path":"/photos/a.jpg"}]}}"#.utf8)
        let call = try JSONDecoder().decode(BridgeCall.self, from: payload)
        XCTAssertEqual(call.id, 4)
        XCTAssertEqual(call.request.version, 7)
        XCTAssertEqual(call.request.targets?.first?.path, "/photos/a.jpg")
        let encoded = try JSONEncoder().encode(call.request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["operation"] as? String, "deleteBatch")
        XCTAssertEqual(json["version"] as? Int, 7)
        // A bare v6 request is not a call.
        XCTAssertNil(try? JSONDecoder().decode(BridgeCall.self, from: Data(#"{"version":6,"operation":"catalog"}"#.utf8)))
    }

    func testGroupingKeepsDocumentsIndependentAndRejectsAmbiguousOwners() {
        let media = ["a.png", "a.jpg", "a.detail.png", "other/a.png"]
        let files = ["a.md", "a.html", "a.json", "a.png.prompt.json", "a.detail.xyz.txt", "other/a.json"]
        XCTAssertEqual(AssetCompanionNames.groups(media: media, files: files), [
            "a.png": ["a.png.prompt.json"], "a.detail.png": ["a.detail.xyz.txt"], "other/a.png": ["other/a.json"]
        ])
        for fixture in CompanionGroupingFixture.all {
            XCTAssertEqual(AssetCompanionNames.groups(media: fixture.files, files: fixture.files), fixture.groups, fixture.name)
        }
    }
}
