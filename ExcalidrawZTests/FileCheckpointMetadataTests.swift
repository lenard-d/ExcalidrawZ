import XCTest
@testable import ExcalidrawZ

final class FileCheckpointMetadataTests: XCTestCase {
    func testCountsActiveElementsLikeTheDrawingDecoder() async throws {
        var stroke = element(id: "stroke", deleted: false)
        stroke["type"] = "freedraw"
        stroke["points"] = (0..<256).map { [$0, $0 % 17] }
        stroke["pressures"] = Array(repeating: 0.5, count: 256)
        let content = try drawing(elements: [
            element(id: "visible", deleted: false),
            element(id: "deleted", deleted: true),
            stroke
        ])
        let file = try JSONDecoder().decode(ExcalidrawFile.self, from: content)

        let metadata = try await FileCheckpointMetadataReader().read(content)

        XCTAssertEqual(metadata.elementCount, 2)
        XCTAssertEqual(metadata.elementCount, file.elements.filter { !$0.isDeleted }.count)
        XCTAssertEqual(metadata.byteCount, content.count)
    }

    func testMissingAndNullElementsMatchEmptyDrawing() async throws {
        for json in [#"{"type":"excalidraw"}"#, #"{"type":"excalidraw","elements":null}"#] {
            let content = Data(json.utf8)
            let file = try JSONDecoder().decode(ExcalidrawFile.self, from: content)

            let metadata = try await FileCheckpointMetadataReader().read(content)

            XCTAssertEqual(metadata.elementCount, file.elements.count)
        }
    }

    func testCountsDoNotRequireDecodingMediaOrPointValues() async throws {
        let content = Data(#"{"type":"excalidraw","elements":[{"type":"freedraw","isDeleted":false,"points":"unreadable"}],"files":"unreadable"}"#.utf8)

        let metadata = try await FileCheckpointMetadataReader().read(content)

        XCTAssertEqual(metadata.elementCount, 1)
        // Row summaries must not replace the full validation used by restore.
        XCTAssertThrowsError(try JSONDecoder().decode(ExcalidrawFile.self, from: content))
    }

    func testUnreadableContentKeepsByteSizeWithoutAnElementCount() async throws {
        for json in ["{", #"{"magic":"EDZENC","payload":{}}"#, #"{"elements":[]}"#] {
            let content = Data(json.utf8)

            let metadata = try await FileCheckpointMetadataReader().read(content)

            XCTAssertNil(metadata.elementCount)
            XCTAssertEqual(metadata.byteCount, content.count)
        }
    }

    func testInvalidDeletionFlagsAndUnknownTypesHaveNoCount() async throws {
        for elementJSON in [
            #"{"type":"rectangle"}"#,
            #"{"type":"rectangle","isDeleted":"false"}"#,
            #"{"type":"future-tool","isDeleted":false}"#
        ] {
            let content = Data("{\"type\":\"excalidraw\",\"elements\":[\(elementJSON)]}".utf8)

            let metadata = try await FileCheckpointMetadataReader().read(content)

            XCTAssertNil(metadata.elementCount)
        }
    }

    func testEachReadUsesItsOwnContentAfterAChangeOrFailure() async throws {
        let reader = FileCheckpointMetadataReader()
        let first = try await reader.read(drawing(elements: [element(id: "first", deleted: false)]))
        let failed = try await reader.read(Data("invalid".utf8))
        let changed = try await reader.read(drawing(elements: [element(id: "first", deleted: true)]))

        XCTAssertEqual(first.elementCount, 1)
        XCTAssertNil(failed.elementCount)
        XCTAssertEqual(changed.elementCount, 0)
    }

    func testCancelledReadDoesNotReturnMetadata() async throws {
        let content = try drawing(elements: [element(id: "visible", deleted: false)])
        let reader = FileCheckpointMetadataReader()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(content)
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled row must not publish metadata")
        } catch is CancellationError {
        }
    }

    private func drawing(elements: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "excalidraw",
            "elements": elements,
            "files": ["image": [
                "id": "image",
                "mimeType": "image/png",
                "dataURL": "data:image/png;base64," + String(repeating: "A", count: 64 * 1024)
            ]]
        ])
    }

    private func element(id: String, deleted: Bool) -> [String: Any] {
        [
            "type": "rectangle", "id": id, "x": 0, "y": 0,
            "strokeColor": "#000000", "backgroundColor": "transparent",
            "fillStyle": "hachure", "strokeWidth": 1, "strokeStyle": "solid",
            "roughness": 1, "opacity": 100, "width": 10, "height": 10,
            "angle": 0, "seed": 1, "version": 1, "versionNonce": 1,
            "isDeleted": deleted, "groupIds": []
        ]
    }
}
