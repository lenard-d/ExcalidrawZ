import Foundation
import XCTest
@testable import ExcalidrawZ

final class ToolbarToolOrderTests: XCTestCase {
    func testAlternateBankKeepsGlobalPositionsIndependentOfDirectCount() {
        var order = ExcalidrawToolbarToolOrder(directToolCount: 6)
        order.move(from: IndexSet(integer: 3), to: 11)
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)

        XCTAssertEqual(restored.directToolCount, 6)
        XCTAssertEqual(restored.tool(forShortcutNumber: 0), .laser)
        XCTAssertEqual(restored.tool(forShortcutNumber: 1, alternate: true), .ellipse)
        XCTAssertEqual(restored.tool(forShortcutNumber: 2, alternate: true), .lasso)
        XCTAssertEqual(restored.tool(forShortcutNumber: 6, alternate: true), .magicFrame)
        XCTAssertEqual(restored.shortcutLabel(for: .ellipse, includingAlternate: true), "⌥1")
        XCTAssertNil(restored.shortcutLabel(for: .ellipse), "Annotation retains first-bank hints only")
        for number in [0, 7, 8, 9, -1, 10, Int.min, Int.max] {
            XCTAssertNil(restored.tool(forShortcutNumber: number, alternate: true))
        }
    }

    func testAddingToolMovesItsShortcutAcrossTheBankBoundary() {
        var order = ExcalidrawToolbarToolOrder()
        XCTAssertEqual(order.tool(forShortcutNumber: 4, alternate: true), .frame)
        order.addDirectTool(.frame)
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)

        XCTAssertEqual(restored.tool(forShortcutNumber: 0), .frame)
        XCTAssertEqual(restored.tool(forShortcutNumber: 1, alternate: true), .eraser)
        XCTAssertEqual(restored.shortcutLabel(for: .frame, includingAlternate: true), "0")
        XCTAssertEqual(restored.shortcutLabel(for: .eraser, includingAlternate: true), "⌥1")
    }

    func testReorderedEllipseKeepsItsNumberAfterReload() {
        var order = ExcalidrawToolbarToolOrder()
        order.move(from: IndexSet(integer: 3), to: 6)

        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        XCTAssertEqual(restored.shortcutLabel(for: .ellipse), "6")
        XCTAssertEqual(restored.tool(forShortcutNumber: 6), .ellipse)
        XCTAssertEqual(restored.tool(forShortcutNumber: 4), .arrow)
    }

    func testExtraToolsUseTheirConfiguredNumberedPositions() {
        let order = ExcalidrawToolbarToolOrder(tools: [
            .frame, .webEmbed, .hand, .laser, .magicFrame, .lasso,
        ])
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)

        XCTAssertEqual(restored.shortcutLabel(for: .frame), "1")
        XCTAssertEqual(restored.tool(forShortcutNumber: 1), .frame)
        XCTAssertEqual(restored.shortcutLabel(for: .webEmbed), "2")
        XCTAssertEqual(restored.tool(forShortcutNumber: 2), .webEmbed)
        XCTAssertEqual(restored.shortcutLabel(for: .lasso), "6")
        XCTAssertEqual(restored.tool(forShortcutNumber: 6), .lasso)
    }

    func testZeroSelectsTenthPositionAndDoesNotAssignBeyondTen() {
        var order = ExcalidrawToolbarToolOrder()
        order.move(from: IndexSet(integer: 3), to: 10)

        XCTAssertEqual(order.shortcutLabel(for: .ellipse), "0")
        XCTAssertEqual(order.tool(forShortcutNumber: 0), .ellipse)
        XCTAssertNil(order.shortcutLabel(for: .laser))
        XCTAssertNil(order.tool(forShortcutNumber: 11))
        XCTAssertNil(order.tool(forShortcutNumber: -1))
        XCTAssertNil(order.tool(forShortcutNumber: Int.min))
        XCTAssertNil(order.tool(forShortcutNumber: Int.max))
    }

    func testStoredOrderDropsUnknownAndDuplicateToolsWithoutLosingDefaults() {
        let order = ExcalidrawToolbarToolOrder(
            storedData: Data(#"["obsolete-tool","ellipse","ellipse"]"#.utf8)
        )

        XCTAssertEqual(order.tool(forShortcutNumber: 1), .ellipse)
        XCTAssertEqual(order.tool(forShortcutNumber: 2), .cursor)
        XCTAssertEqual(Set(order.tools), Set(ExcalidrawToolbarToolOrder.defaultTools))
        XCTAssertEqual(order.tools.count, ExcalidrawToolbarToolOrder.defaultTools.count)
    }

    func testInvalidStoredOrderFallsBackToDefaultShortcuts() {
        for data in [Data(), Data("invalid JSON".utf8), Data("{}".utf8)] {
            let order = ExcalidrawToolbarToolOrder(storedData: data)
            XCTAssertEqual(order.tool(forShortcutNumber: 4), .ellipse)
            XCTAssertEqual(order.tool(forShortcutNumber: 0), .eraser)
        }
    }

    func testWebLassoSelectionKeepsLassoShortcutAndSelectionIdentity() {
        let mirroredTool = ExcalidrawTool(from: .lasso)
        let order = ExcalidrawToolbarToolOrder(tools: [.lasso, .cursor])

        XCTAssertEqual(mirroredTool, .lasso)
        XCTAssertEqual(order.tool(forShortcutNumber: 1), mirroredTool)
        XCTAssertEqual(order.shortcutLabel(for: .cursor), "2")
        XCTAssertEqual(ExcalidrawTool(from: .selection), .cursor)
    }
}
