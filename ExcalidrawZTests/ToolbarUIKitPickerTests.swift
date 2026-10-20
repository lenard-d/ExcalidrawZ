#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import ExcalidrawZ

@MainActor
final class ToolbarUIKitPickerTests: XCTestCase {
    func testNativeActionsUseReloadedConfiguredToolsAcrossEveryPartition() {
        var order = ExcalidrawToolbarToolOrder(tools: [.frame, .lasso, .hand, .webEmbed])
        order.move(from: IndexSet(integer: 7), to: 1)
        order = ExcalidrawToolbarToolOrder(storedData: order.storedData)
        var selected: ExcalidrawTool? = .cursor
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let coordinator = ExcalidrawToolbarUIKitPicker.Coordinator(selection: binding)
        let control = coordinator.makeControl()

        for sizeClass: ExcalidrawToolbarToolSizeClass in [.compact, .regular, .expanded] {
            let items = ExcalidrawToolbarToolPresentation(order: order).pickerItems(for: sizeClass).primary
            coordinator.update(control, items: items, selection: binding, size: 20, withFooter: true, scale: 1)
            XCTAssertEqual(control.numberOfSegments, items.count)
            for (index, item) in items.enumerated() {
                XCTAssertNotNil(control.imageForSegment(at: index))
                XCTAssertEqual(
                    control.imageForSegment(at: index)?.accessibilityLabel,
                    item.menuTitle(localizedName: item.tool.localization)
                )
                control.selectedSegmentIndex = index
                control.sendActions(for: .valueChanged)
                XCTAssertEqual(selected, item.tool)
                if let digit = item.shortcutLabel, let number = Int(digit) {
                    XCTAssertEqual(selected, order.tool(forShortcutNumber: number))
                }
                coordinator.update(control, items: items, selection: binding, size: 20, withFooter: true, scale: 1)
                XCTAssertEqual(control.selectedSegmentIndex, index, "A render after release must retain the committed tool")
            }
        }
    }

    func testExternalSelectionAndOverflowDoNotSelectAnotherVisibleTool() {
        let presentation = ExcalidrawToolbarToolPresentation(order: .init())
        let items = presentation.pickerItems(for: .compact).primary
        var selected: ExcalidrawTool? = .ellipse
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let coordinator = ExcalidrawToolbarUIKitPicker.Coordinator(selection: binding)
        let control = coordinator.makeControl()
        coordinator.update(control, items: items, selection: binding, size: 20, withFooter: true, scale: 1)
        XCTAssertEqual(control.selectedSegmentIndex, items.firstIndex { $0.tool == .ellipse })

        selected = .magicFrame
        coordinator.update(control, items: items, selection: binding, size: 20, withFooter: true, scale: 1)
        XCTAssertEqual(control.selectedSegmentIndex, UISegmentedControl.noSegment)
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(selected, .magicFrame)

        selected = nil
        coordinator.update(control, items: items, selection: binding, size: 20, withFooter: false, scale: 2)
        XCTAssertEqual(control.selectedSegmentIndex, UISegmentedControl.noSegment)
    }

    func testReorderRefreshesDisplayedActionMappingAndBinding() {
        var selected: ExcalidrawTool? = .ellipse
        let oldBinding = Binding(get: { selected }, set: { selected = $0 })
        let coordinator = ExcalidrawToolbarUIKitPicker.Coordinator(selection: oldBinding)
        let control = coordinator.makeControl()
        let initial = ExcalidrawToolbarToolPresentation(order: .init()).items
        coordinator.update(control, items: initial, selection: oldBinding, size: 20, withFooter: true, scale: 1)

        var newSelection: ExcalidrawTool? = .ellipse
        let newBinding = Binding(get: { newSelection }, set: { newSelection = $0 })
        let reordered = ExcalidrawToolbarToolPresentation(order: .init(tools: [.laser, .ellipse])).items
        coordinator.update(control, items: reordered, selection: newBinding, size: 20, withFooter: true, scale: 1)
        XCTAssertEqual(control.selectedSegmentIndex, 1)
        XCTAssertEqual(control.imageForSegment(at: 0)?.accessibilityLabel, "\(ExcalidrawTool.laser.localization) (1)")
        XCTAssertEqual(control.imageForSegment(at: 1)?.accessibilityLabel, "\(ExcalidrawTool.ellipse.localization) (2)")
        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(newSelection, .laser)
        XCTAssertEqual(selected, .ellipse)
    }
}
#endif
