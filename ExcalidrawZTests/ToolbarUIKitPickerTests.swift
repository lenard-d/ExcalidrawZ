#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import ExcalidrawZ

@MainActor
final class ToolbarUIKitPickerTests: XCTestCase {
    func testContactPreviewsBothDirectionsButCommitsOnlyRelease() {
        let items = ExcalidrawToolbarToolPresentation(order: .init(tools: [.laser, .frame, .ellipse])).items
        var selected: ExcalidrawTool? = .cursor
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let (coordinator, control) = makePicker(items: items, selection: binding)

        coordinator.beginContact(control, at: CGPoint(x: 20, y: 22))
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        XCTAssertEqual(selected, .cursor)
        coordinator.moveContact(control, to: CGPoint(x: 260, y: 22))
        XCTAssertEqual(control.selectedSegmentIndex, 6)
        coordinator.moveContact(control, to: CGPoint(x: 100, y: 22))
        XCTAssertEqual(control.selectedSegmentIndex, 2)
        // The former divider belongs to the next segment without a gap.
        coordinator.moveContact(control, to: CGPoint(x: 40, y: 22))
        XCTAssertEqual(control.selectedSegmentIndex, 1)
        XCTAssertEqual(selected, .cursor)
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(selected, .cursor, "Native valueChanged must not commit a held preview")
        coordinator.endContact(control, at: CGPoint(x: 100, y: 22))
        XCTAssertEqual(selected, .ellipse)
        XCTAssertEqual(control.selectedSegmentIndex, 2)

        coordinator.beginContact(control, at: CGPoint(x: 20, y: 22))
        coordinator.endContact(control, at: CGPoint(x: 20, y: 22))
        XCTAssertEqual(selected, .laser, "An ordinary quick tap must commit its own tool")
    }

    func testCancelOutsideAndNonTouchSelectionUseCurrentBinding() async {
        let items = ExcalidrawToolbarToolPresentation(order: .init()).items
        var selected: ExcalidrawTool? = .ellipse
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let (coordinator, control) = makePicker(items: items, selection: binding)
        coordinator.beginContact(control, at: CGPoint(x: 20, y: 22))
        control.sendActions(for: .touchCancel)
        XCTAssertEqual(selected, .ellipse)
        XCTAssertEqual(control.selectedSegmentIndex, 3)

        coordinator.beginContact(control, at: CGPoint(x: 20, y: 22))
        coordinator.moveContact(control, to: CGPoint(x: -1, y: 22))
        XCTAssertEqual(control.selectedSegmentIndex, 3)
        coordinator.endContact(control, at: CGPoint(x: -1, y: 22))
        XCTAssertEqual(selected, .ellipse)
        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(selected, .ellipse, "A trailing native event must not undo cancellation")
        let settled = expectation(description: "Native touch event has ended")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 1)
        control.selectedSegmentIndex = 5
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(selected, .line, "Accessibility and keyboard valueChanged need no touch event")
    }

    func testExternalSelectionAndReorderInvalidateHeldCommit() async {
        let initial = ExcalidrawToolbarToolPresentation(order: .init()).items
        var oldSelection: ExcalidrawTool? = .cursor
        let oldBinding = Binding(get: { oldSelection }, set: { oldSelection = $0 })
        let (coordinator, control) = makePicker(items: initial, selection: oldBinding)
        coordinator.beginContact(control, at: CGPoint(x: 100, y: 22))

        var selected: ExcalidrawTool? = .ellipse
        let newBinding = Binding(get: { selected }, set: { selected = $0 })
        let reordered = ExcalidrawToolbarToolPresentation(order: .init(tools: [.laser, .ellipse])).items
        coordinator.update(control, items: reordered, selection: newBinding, size: 20, withFooter: true, scale: 1)
        XCTAssertEqual(control.imageForSegment(at: 0)?.accessibilityLabel,
                       initial[0].menuTitle(localizedName: initial[0].tool.localization))
        coordinator.moveContact(control, to: CGPoint(x: 20, y: 22))
        coordinator.endContact(control, at: CGPoint(x: 20, y: 22))
        XCTAssertEqual(selected, .ellipse)
        XCTAssertEqual(oldSelection, .cursor)

        let rendered = expectation(description: "Deferred render after contact ends")
        DispatchQueue.main.async { rendered.fulfill() }
        await fulfillment(of: [rendered], timeout: 1)
        XCTAssertEqual(control.imageForSegment(at: 0)?.accessibilityLabel,
                       reordered[0].menuTitle(localizedName: reordered[0].tool.localization))
        XCTAssertEqual(control.selectedSegmentIndex, 1)
        coordinator.beginContact(control, at: CGPoint(x: 20, y: 22))
        coordinator.endContact(control, at: CGPoint(x: 20, y: 22))
        XCTAssertEqual(selected, .laser)
    }

    func testContactUsesPublicRightToLeftLayoutAndRejectsDisabledSegments() {
        let items = ExcalidrawToolbarToolPresentation(order: .init()).items
        var selected: ExcalidrawTool? = .cursor
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let (coordinator, control) = makePicker(items: items, selection: binding)
        control.semanticContentAttribute = .forceRightToLeft
        XCTAssertEqual(control.effectiveUserInterfaceLayoutDirection, .rightToLeft)
        coordinator.beginContact(control, at: CGPoint(x: control.bounds.maxX - 20, y: 22))
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        coordinator.moveContact(control, to: CGPoint(x: 20, y: 22))
        XCTAssertEqual(control.selectedSegmentIndex, items.count - 1)
        coordinator.endContact(control, at: CGPoint(x: 20, y: 22))
        XCTAssertEqual(selected, items.last?.tool)

        control.setEnabled(false, forSegmentAt: 0)
        coordinator.beginContact(control, at: CGPoint(x: control.bounds.maxX - 20, y: 22))
        coordinator.endContact(control, at: CGPoint(x: control.bounds.maxX - 20, y: 22))
        XCTAssertEqual(selected, items.last?.tool)
    }

    private func makePicker(
        items: [ExcalidrawToolbarToolPresentation.Item], selection: Binding<ExcalidrawTool?>
    ) -> (ExcalidrawToolbarUIKitPicker.Coordinator, UISegmentedControl) {
        let coordinator = ExcalidrawToolbarUIKitPicker.Coordinator(selection: selection)
        let control = coordinator.makeControl()
        coordinator.update(control, items: items, selection: selection, size: 20, withFooter: true, scale: 1)
        control.frame = CGRect(x: 0, y: 0, width: CGFloat(items.count) * 40, height: 44)
        return (coordinator, control)
    }

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
