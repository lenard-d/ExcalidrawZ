import XCTest
@testable import ExcalidrawZ

final class PageModePersistenceTests: XCTestCase {
    func testNativeFrameRoundTripRetainsPageOrderNameAndForeignMetadata() throws {
        let input = ##"{"type":"frame","id":"notes","x":12,"y":34,"width":595,"height":842,"strokeColor":"#000000","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"angle":0,"seed":7,"version":1,"versionNonce":8,"isDeleted":false,"groupIds":[],"name":"Exercise 2","customData":{"excalidrawZPage":{"version":1,"order":3},"foreign":{"keep":"value"}}}"##
        let frame = try JSONDecoder().decode(ExcalidrawFrameLikeElement.self, from: Data(input.utf8))
        let encoded = try JSONEncoder().encode(frame)
        let reloaded = try JSONDecoder().decode(ExcalidrawFrameLikeElement.self, from: encoded)
        XCTAssertEqual(reloaded.type, .frame)
        XCTAssertEqual(reloaded.name, "Exercise 2")
        XCTAssertEqual(reloaded.customData, frame.customData)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let customData = try XCTUnwrap(object["customData"] as? [String: Any])
        let page = try XCTUnwrap(customData["excalidrawZPage"] as? [String: Any])
        XCTAssertEqual(page["order"] as? Int, 3)
        XCTAssertEqual((customData["foreign"] as? [String: String])?["keep"], "value")
        XCTAssertEqual(reloaded.x, 12)
        XCTAssertEqual(reloaded.y, 34)
    }
}
