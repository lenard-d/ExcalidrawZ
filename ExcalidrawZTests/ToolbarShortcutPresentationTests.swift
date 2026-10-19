import Foundation
import XCTest
@testable import ExcalidrawZ

final class ToolbarShortcutPresentationTests: XCTestCase {
    func testEveryPickerPartitionKeepsTheConfiguredKeyRoutes() {
        let order = ExcalidrawToolbarToolOrder(tools: [
            .frame, .lasso, .webEmbed, .hand, .laser, .magicFrame,
        ])
        let presentation = ExcalidrawToolbarToolPresentation(order: order)

        for sizeClass: ExcalidrawToolbarToolSizeClass in [.dense, .compact, .regular, .expanded] {
            let partition = presentation.pickerItems(for: sizeClass)
            let tools = order.pickerItems(for: sizeClass)
            XCTAssertEqual(partition.primary.map(\.tool), tools.primary)
            XCTAssertEqual(partition.secondary.map(\.tool), tools.secondary)
            XCTAssertEqual(partition.primary + partition.secondary, presentation.items)
            assertMenuRoutes(partition.primary + partition.secondary, order: order)
        }
    }

    func testMovingEllipseIntoAndOutOfOverflowUpdatesItsVisibleDigit() throws {
        var order = ExcalidrawToolbarToolOrder()
        order.move(from: IndexSet(integer: 3), to: 10)
        let overflow = ExcalidrawToolbarToolPresentation(order: order).pickerItems(for: .regular)
        let ellipse = try XCTUnwrap(overflow.secondary.first { $0.tool == .ellipse })
        XCTAssertEqual(ellipse.menuTitle(localizedName: "Ellipse"), "Ellipse (0)")
        XCTAssertEqual(order.tool(forShortcutNumber: 0), ellipse.tool)
        assertMenuRoutes(overflow.primary + overflow.secondary, order: order)

        order.move(from: IndexSet(integer: 9), to: 1)
        let primary = ExcalidrawToolbarToolPresentation(order: order).pickerItems(for: .regular)
        let moved = try XCTUnwrap(primary.primary.first { $0.tool == .ellipse })
        XCTAssertEqual(moved.menuTitle(localizedName: "Ellipse"), "Ellipse (2)")
        XCTAssertFalse(primary.secondary.contains { $0.tool == .ellipse })
        assertMenuRoutes(primary.primary + primary.secondary, order: order)
    }

    func testCompactFilterKeepsGapsAndGlobalDigitsAfterReload() throws {
        let stored = ExcalidrawToolbarToolOrder(tools: [
            .cursor, .hand, .frame, .freedraw, .webEmbed, .lasso, .magicFrame,
        ]).storedData
        let order = ExcalidrawToolbarToolOrder(storedData: stored)
        let items = ExcalidrawToolbarToolPresentation(order: order).compactItems

        XCTAssertEqual(items.map(\.tool), order.tools.filter {
            ![ExcalidrawTool.cursor, .hand, .freedraw, .lasso].contains($0)
        })
        let frame = try XCTUnwrap(items.first { $0.tool == .frame })
        let embed = try XCTUnwrap(items.first { $0.tool == .webEmbed })
        XCTAssertEqual(frame.menuTitle(localizedName: "Rahmen"), "Rahmen (3)")
        XCTAssertEqual(embed.menuTitle(localizedName: "Web einbetten"), "Web einbetten (5)")
        assertMenuRoutes(items, order: order)
    }

    func testToolsBeyondTenHaveNoFalseHintInAnyMenu() throws {
        var order = ExcalidrawToolbarToolOrder(tools: [.magicFrame])
        order.move(from: IndexSet(integer: 0), to: 11)
        let presentation = ExcalidrawToolbarToolPresentation(order: order)
        let item = try XCTUnwrap(presentation.compactItems.first { $0.tool == .magicFrame })

        XCTAssertNil(item.shortcutLabel)
        XCTAssertEqual(item.menuTitle(localizedName: "KI-Rahmen"), "KI-Rahmen")
        assertMenuRoutes(presentation.items, order: order)
        assertMenuRoutes(presentation.compactItems, order: order)
    }

    func testReorderedStoredOrderRestoresAllMenuPresentationInputs() {
        var order = ExcalidrawToolbarToolOrder()
        order.move(from: IndexSet([3, 13, 14]), to: 1)
        let restored = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        let before = ExcalidrawToolbarToolPresentation(order: order)
        let after = ExcalidrawToolbarToolPresentation(order: restored)

        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.compactItems, before.compactItems)
        assertMenuRoutes(after.items, order: restored)
    }

    private func assertMenuRoutes(
        _ items: [ExcalidrawToolbarToolPresentation.Item],
        order: ExcalidrawToolbarToolOrder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for item in items {
            let routedNumber = (0...9).first { order.tool(forShortcutNumber: $0) == item.tool }
            let name = "Localized tool"
            let expectedTitle = routedNumber.map { "\(name) (\($0))" } ?? name
            XCTAssertEqual(item.menuTitle(localizedName: name), expectedTitle, file: file, line: line)
        }
    }
}
