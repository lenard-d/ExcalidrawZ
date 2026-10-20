#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import ExcalidrawZ

@MainActor
final class ToolbarUIKitPickerTests: XCTestCase {
    // These inputs exercise the production recognizer handler. Root's UI run verifies recognition.
    private final class ScrubInput: UILongPressGestureRecognizer {
        var phase: UIGestureRecognizer.State = .possible
        var point = CGPoint.zero
        override var state: UIGestureRecognizer.State {
            get { phase }
            set { phase = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private func send(
        _ phase: UIGestureRecognizer.State, at point: CGPoint,
        through gesture: ScrubInput, to coordinator: ExcalidrawToolbarUIKitPicker.Coordinator
    ) {
        gesture.phase = phase
        gesture.point = point
        coordinator.handleScrub(gesture)
    }

    func testScrubPreviewsBothDirectionsAndCommitsOnlyOnRelease() {
        let items = ExcalidrawToolbarToolPresentation(order: .init(tools: [.laser, .frame, .ellipse])).items
        var selected: ExcalidrawTool? = .cursor
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let (coordinator, control) = makePicker(items: items, selection: binding)
        let gesture = ScrubInput()
        control.addGestureRecognizer(gesture)

        send(.began, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        XCTAssertEqual(selected, .cursor)
        send(.changed, at: CGPoint(x: 260, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(control.selectedSegmentIndex, 6)
        send(.changed, at: CGPoint(x: 100, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(control.selectedSegmentIndex, 2)
        send(.changed, at: CGPoint(x: 40, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(control.selectedSegmentIndex, 1, "There is no gap at a former divider")
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(selected, .cursor, "A native action must not commit a held preview")
        send(.ended, at: CGPoint(x: 100, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(selected, .ellipse)
        XCTAssertEqual(control.selectedSegmentIndex, 2)

        send(.began, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        send(.ended, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(selected, .laser, "A quick tap commits its own tool")
    }

    func testCancellationAndOutsideReleaseRestoreBindingAndAllowAccessibilityActions() {
        let items = ExcalidrawToolbarToolPresentation(order: .init()).items
        var selected: ExcalidrawTool? = .ellipse
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let (coordinator, control) = makePicker(items: items, selection: binding)
        let gesture = ScrubInput()
        control.addGestureRecognizer(gesture)

        for terminal: UIGestureRecognizer.State in [.cancelled, .failed, .ended] {
            send(.began, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
            send(.changed, at: CGPoint(x: -1, y: 22), through: gesture, to: coordinator)
            XCTAssertEqual(control.selectedSegmentIndex, 3)
            send(terminal, at: CGPoint(x: -1, y: 22), through: gesture, to: coordinator)
            XCTAssertEqual(selected, .ellipse)
            XCTAssertEqual(control.selectedSegmentIndex, 3)
        }
        control.selectedSegmentIndex = 5
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(selected, .line, "Accessibility and keyboard actions need no contact")
    }

    func testExternalBindingAndReorderInvalidateHeldCommit() {
        let initial = ExcalidrawToolbarToolPresentation(order: .init()).items
        var oldSelection: ExcalidrawTool? = .cursor
        let oldBinding = Binding(get: { oldSelection }, set: { oldSelection = $0 })
        let (coordinator, control) = makePicker(items: initial, selection: oldBinding)
        let gesture = ScrubInput()
        control.addGestureRecognizer(gesture)
        send(.began, at: CGPoint(x: 100, y: 22), through: gesture, to: coordinator)

        var selected: ExcalidrawTool? = .ellipse
        let newBinding = Binding(get: { selected }, set: { selected = $0 })
        let reordered = ExcalidrawToolbarToolPresentation(order: .init(tools: [.laser, .ellipse])).items
        coordinator.update(control, items: reordered, selection: newBinding, size: 20, withFooter: true, scale: 1)
        XCTAssertEqual(control.imageForSegment(at: 0)?.accessibilityLabel,
                       initial[0].menuTitle(localizedName: initial[0].tool.localization))
        send(.changed, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        send(.ended, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(selected, .ellipse)
        XCTAssertEqual(oldSelection, .cursor)
        XCTAssertEqual(control.imageForSegment(at: 0)?.accessibilityLabel,
                       reordered[0].menuTitle(localizedName: reordered[0].tool.localization))
        XCTAssertEqual(control.selectedSegmentIndex, 1)
        send(.began, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        send(.ended, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(selected, .laser)
    }

    func testScrubUsesRightToLeftLayoutAndRejectsDisabledSegments() {
        let items = ExcalidrawToolbarToolPresentation(order: .init()).items
        var selected: ExcalidrawTool? = .cursor
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let (coordinator, control) = makePicker(items: items, selection: binding)
        let gesture = ScrubInput()
        control.addGestureRecognizer(gesture)
        control.semanticContentAttribute = .forceRightToLeft
        XCTAssertEqual(control.effectiveUserInterfaceLayoutDirection, .rightToLeft)
        send(.began, at: CGPoint(x: control.bounds.maxX - 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        send(.changed, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(control.selectedSegmentIndex, items.count - 1)
        send(.ended, at: CGPoint(x: 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(selected, items.last?.tool)

        control.setEnabled(false, forSegmentAt: 0)
        send(.began, at: CGPoint(x: control.bounds.maxX - 20, y: 22), through: gesture, to: coordinator)
        send(.ended, at: CGPoint(x: control.bounds.maxX - 20, y: 22), through: gesture, to: coordinator)
        XCTAssertEqual(selected, items.last?.tool)
        control.isEnabled = false
        let otherEnabledSegment = CGPoint(x: control.bounds.maxX - 60, y: 22)
        send(.began, at: otherEnabledSegment, through: gesture, to: coordinator)
        XCTAssertEqual(control.selectedSegmentIndex, items.count - 1)
        send(.ended, at: otherEnabledSegment, through: gesture, to: coordinator)
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
