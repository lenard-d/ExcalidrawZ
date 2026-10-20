import Foundation
import XCTest
@testable import ExcalidrawZ

final class ToolbarDirectToolConfigurationTests: XCTestCase {
    func testLegacyOrderKeepsSequenceAndNineDirectTools() throws {
        let ids = ["eraser", "cursor", "rectangle", "diamond", "ellipse", "arrow", "line",
                   "freedraw", "text", "laser", "image", "lasso", "hand", "frame", "webEmbed", "magicFrame"]
        let order = ExcalidrawToolbarToolOrder(storedData: try JSONEncoder().encode(ids))
        let presentation = ExcalidrawToolbarToolPresentation(order: order)

        XCTAssertEqual(order.tools.map(\.toolbarOrderID), ids)
        XCTAssertEqual(order.directToolCount, 9)
        XCTAssertEqual(presentation.configuredDirectItems.map(\.tool), Array(order.tools.prefix(9)))
        XCTAssertEqual(presentation.configuredOverflowItems.map(\.tool), Array(order.tools.dropFirst(9)))
    }

    func testAddingOverflowToolMovesItToDirectBoundaryAndSurvivesReload() {
        var order = ExcalidrawToolbarToolOrder()
        let originalDirect = Array(order.tools.prefix(9))
        order.addDirectTool(.frame)
        order.addDirectTool(.frame)

        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        let presentation = ExcalidrawToolbarToolPresentation(order: restored)
        XCTAssertEqual(restored.directToolCount, 10)
        XCTAssertEqual(presentation.configuredDirectItems.map(\.tool), originalDirect + [.frame])
        XCTAssertFalse(presentation.configuredOverflowItems.contains { $0.tool == .frame })
        XCTAssertEqual(restored.tool(forShortcutNumber: 0), .frame)
        XCTAssertEqual(presentation.configuredDirectItems.last?.shortcutLabel, "0")
        XCTAssertEqual(restored, order)
    }

    func testReorderingKeepsDirectCountAndStoredBoundary() {
        var order = ExcalidrawToolbarToolOrder()
        order.addDirectTool(.frame)
        order.move(from: IndexSet(integer: 9), to: 1)
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        let presentation = ExcalidrawToolbarToolPresentation(order: restored)

        XCTAssertEqual(restored.directToolCount, 10)
        XCTAssertEqual(presentation.configuredDirectItems[1].tool, .frame)
        XCTAssertEqual(restored.tool(forShortcutNumber: 2), .frame)
        XCTAssertEqual(restored.tools.count, Set(restored.tools).count)
    }

    func testConfiguredPartitionsDoNotExpandDefaultsOrChangeGenericPicker() {
        var order = ExcalidrawToolbarToolOrder()
        XCTAssertEqual(ExcalidrawToolbarToolPresentation(order: order)
            .configuredPickerItems(for: .expanded).primary.count, 9)
        order.addDirectTool(.laser)
        order.addDirectTool(.frame)
        let presentation = ExcalidrawToolbarToolPresentation(order: order)

        for size: ExcalidrawToolbarToolSizeClass in [.dense, .compact, .regular, .expanded] {
            let partition = presentation.configuredPickerItems(for: size)
            XCTAssertEqual(partition.primary.count, size == .dense || size == .compact ? 6 : 11)
            XCTAssertEqual(partition.primary + partition.secondary, presentation.items)
            for item in partition.primary + partition.secondary {
                if let label = item.shortcutLabel, let number = Int(label) {
                    XCTAssertEqual(order.tool(forShortcutNumber: number), item.tool)
                }
            }
        }
        XCTAssertEqual(presentation.pickerItems(for: .expanded).primary.map(\.tool), order.tools)
        XCTAssertTrue(presentation.pickerItems(for: .expanded).secondary.isEmpty)
        XCTAssertEqual(order.directToolCount, 11)
    }

    func testEnvelopePreservesOrderWithMissingOrInvalidCount() {
        for count in ["", #", "directToolCount": null"#, #", "directToolCount": "ten""#] {
            let data = Data("{\"tools\":[\"ellipse\",\"cursor\"]\(count)}".utf8)
            let order = ExcalidrawToolbarToolOrder(storedData: data)
            XCTAssertEqual(order.tools.first, .ellipse)
            XCTAssertEqual(order.directToolCount, 9)
        }
    }

    func testCountBoundsAndAddingEveryRemainingTool() {
        let low = ExcalidrawToolbarToolOrder(storedData: Data(#"{"tools":["ellipse"],"directToolCount":-1}"#.utf8))
        let high = ExcalidrawToolbarToolOrder(storedData: Data(#"{"tools":["ellipse"],"directToolCount":1000}"#.utf8))
        XCTAssertEqual(low.directToolCount, 1)
        XCTAssertEqual(high.directToolCount, high.tools.count)
        var order = ExcalidrawToolbarToolOrder()
        for tool in order.tools { order.addDirectTool(tool) }
        XCTAssertEqual(order.directToolCount, order.tools.count)
        XCTAssertTrue(ExcalidrawToolbarToolPresentation(order: order).configuredOverflowItems.isEmpty)
        XCTAssertEqual(ExcalidrawToolbarToolOrder().directToolCount, 9)
    }
}
