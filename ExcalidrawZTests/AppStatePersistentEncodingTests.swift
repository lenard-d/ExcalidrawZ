import Foundation
import XCTest
@testable import ExcalidrawZ

final class AppStatePersistentEncodingTests: XCTestCase {
    private indirect enum Value: Encodable {
        case number(Int)
        case branch(Value)
        case unreadable

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
                case .number(let number): try container.encode(number)
                case .branch(let child): try container.encode(["child": child])
                case .unreadable: throw CocoaError(.coderInvalidValue)
            }
        }
    }

    func testDiscardedDeepRuntimeBranchIsNotEncoded() throws {
        var deep = Value.unreadable
        for _ in 0..<256 { deep = .branch(deep) }
        let data = try ExcalidrawDocumentAppStatePersistence.appStateOnlyPersistentData(
            from: ["runtimeUnknown": deep, "gridSize": .number(20)]
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        XCTAssertEqual(object, ["gridSize": 20])
    }

    func testKeptValuesMatchExistingPersistentFilter() throws {
        let input = ["gridSize": 20, "currentItemStrokeWidthKey": 3, "scrollX": 99]
        let filtered = ExcalidrawDocumentAppStatePersistence.appStateObjectByKeepingAppStateOnlyPersistentFields(from: input)
        let data = try ExcalidrawDocumentAppStatePersistence.appStateOnlyPersistentData(from: input)
        let object = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        XCTAssertEqual(object, filtered as NSDictionary)
    }

    func testInvalidKeptValueStillPropagatesEncodingFailure() {
        XCTAssertThrowsError(try ExcalidrawDocumentAppStatePersistence.appStateOnlyPersistentData(
            from: ["gridSize": Value.unreadable]
        ))
    }
}
