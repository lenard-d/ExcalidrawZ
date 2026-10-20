import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit

final class ToolbarScrubSelectionTests: XCTestCase {
    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["EXCALIDRAWZ_ISOLATED_UI_TESTS"] == "1" else {
            throw NSError(domain: "ToolbarScrubSelectionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Root must inspect the isolated simulator app identity and data paths first."])
        }
    }

    override func tearDownWithError() throws {
        launchedApp?.terminate()
        launchedApp = nil
        XCUIDevice.shared.orientation = .portrait
    }

    func testRealToolQuickTapsAndBothScrubDirections() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        XCTAssertTrue(control.isHittable)
        XCTAssertGreaterThanOrEqual(control.buttons.count, 6)
        XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
        XCTAssertLessThanOrEqual(control.frame.maxX, app.windows.firstMatch.frame.maxX)
        let canvas = app.webViews.firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(canvas.frame.width, 300)
        XCTAssertGreaterThan(canvas.frame.height, 300)

        for index in [2, 0, 1] {
            control.buttons.element(boundBy: index).tap()
            assertSelection(index, control: control)
        }
        let diamond = tool(named: "Diamond", in: control)
        XCTAssertTrue(diamond.exists, "The drawing proof needs the observed Diamond action")
        diamond.tap()
        assertSelection(diamond, control: control)
        drag(in: canvas, from: CGVector(dx: 0.25, dy: 0.35), to: CGVector(dx: 0.40, dy: 0.55))
        capture(app, name: "Canvas diamond after quick tap, inspect actual shape")

        let cursor = tool(named: "Selection", in: control)
        let line = tool(named: "Line", in: control)
        // Six visible tools in the preserved order include Arrow; Line is in overflow.
        let endpoint = line.exists ? line : tool(named: "Arrow", in: control)
        XCTAssertTrue(cursor.exists)
        XCTAssertTrue(endpoint.exists, "Need a visible named Line or Arrow action for the scrub proof")
        XCTAssertLessThan(cursor.frame.midX, endpoint.frame.midX)
        // Root records this held contact to inspect the control's selection background before release.
        cursor.press(forDuration: 0.3, thenDragTo: endpoint, withVelocity: .slow, thenHoldForDuration: 3)
        assertSelection(endpoint, control: control)
        drag(in: canvas, from: CGVector(dx: 0.55, dy: 0.35), to: CGVector(dx: 0.75, dy: 0.55))
        capture(app, name: "Canvas after forward scrub to \(endpoint.label), inspect that tool result")

        endpoint.press(forDuration: 0.3, thenDragTo: cursor, withVelocity: .slow, thenHoldForDuration: 3)
        assertSelection(cursor, control: control)
        drag(in: canvas, from: CGVector(dx: 0.20, dy: 0.30), to: CGVector(dx: 0.45, dy: 0.60))
        capture(app, name: "Canvas diamond selection after reverse scrub, inspect selection handles")

        // Start at the former divider between the second and third tools.
        let second = control.buttons.element(boundBy: 1)
        let boundary = control.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: second.frame.maxX - control.frame.minX, dy: control.frame.height / 2)
        )
        boundary.press(forDuration: 0.3, thenDragTo: endpoint.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        assertSelection(endpoint, control: control)
        endpoint.tap()
        assertSelection(endpoint, control: control)

        // Leave vertically so Selection is the last contacted tool, not a crossed neighbor.
        let outside = cursor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: control.frame.maxY - cursor.frame.midY + 60))
        cursor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.3, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.3
        )
        capture(app, name: "Outside release must retain the last contacted Selection tool")
        assertSelection(cursor, control: control)
        cursor.tap()
        assertSelection(cursor, control: control)

        capture(app, name: "Real configured tools after quick taps and forward-reverse scrub")
        // Post-release assertions do not establish the selection shown during either held contact.
    }

    func testOutsideReleaseKeepsLastContactedToolOnCanvas() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let cursor = tool(named: "Selection", in: control)
        let diamond = tool(named: "Diamond", in: control)
        XCTAssertTrue(cursor.isHittable)
        XCTAssertTrue(diamond.isHittable)
        let canvas = app.webViews.firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))

        cursor.tap()
        assertSelection(cursor, control: control)
        let start = diamond.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = start.withOffset(CGVector(dx: 0, dy: control.frame.maxY - diamond.frame.midY + 60))
        // Root records both holds to inspect first contact and retained selection below the row.
        start.press(forDuration: 3, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 3)
        capture(app, name: "Diamond after release below the tool row")
        assertSelection(diamond, control: control)
        drag(in: canvas, from: CGVector(dx: 0.25, dy: 0.35), to: CGVector(dx: 0.40, dy: 0.55))
        capture(app, name: "Canvas diamond after outside release, inspect actual shape")
        cursor.tap()
        assertSelection(cursor, control: control)
    }

    func testHeldContactStartsOnAnUnselectedToolInBothDirections() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let cursor = tool(named: "Selection", in: control)
        let diamond = tool(named: "Diamond", in: control)
        let line = tool(named: "Line", in: control)
        let endpoint = line.exists ? line : tool(named: "Arrow", in: control)
        XCTAssertTrue(cursor.isHittable)
        XCTAssertTrue(diamond.isHittable)
        XCTAssertTrue(endpoint.isHittable)
        XCTAssertLessThan(cursor.frame.midX, diamond.frame.midX)
        XCTAssertLessThan(diamond.frame.midX, endpoint.frame.midX)

        cursor.tap()
        assertSelection(cursor, control: control)
        capture(app, name: "Selection committed before contact on unselected Diamond")
        // Root inspects the first three seconds for native glass movement before the drag.
        diamond.press(forDuration: 3, thenDragTo: endpoint, withVelocity: .slow, thenHoldForDuration: 3)
        assertSelection(endpoint, control: control)
        capture(app, name: "Forward release after unselected Diamond origin")

        diamond.press(forDuration: 3, thenDragTo: cursor, withVelocity: .slow, thenHoldForDuration: 3)
        assertSelection(cursor, control: control)
        capture(app, name: "Reverse release after unselected Diamond origin")
        diamond.tap()
        assertSelection(diamond, control: control)
        cursor.tap()
        assertSelection(cursor, control: control)
        // Post-release assertions do not prove native glass animation during contact.
    }

    func testStableLockAndCombinedToolActionsMenu() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let lock = app.buttons["toolbar.toolLock"].firstMatch
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        XCTAssertTrue(lock.isHittable)
        XCTAssertTrue(menu.isHittable)
        let originalFrame = lock.frame
        XCTAssertEqual(originalFrame.width, menu.frame.width, accuracy: 1)
        XCTAssertEqual(originalFrame.height, menu.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(originalFrame.width, 44)
        XCTAssertGreaterThanOrEqual(originalFrame.height, 44)

        let initialLockState = lock.isSelected
        lock.tap()
        waitForSelectedState(!initialLockState, of: lock)
        capture(app, name: "Tool lock after confirmed state change")
        XCTAssertEqual(lock.frame.width, originalFrame.width, accuracy: 1)
        XCTAssertEqual(lock.frame.height, originalFrame.height, accuracy: 1)
        lock.tap()
        waitForSelectedState(initialLockState, of: lock)
        capture(app, name: "Tool lock after restoring initial state")
        XCTAssertEqual(lock.frame.width, originalFrame.width, accuracy: 1)
        XCTAssertEqual(lock.frame.height, originalFrame.height, accuracy: 1)

        let cursor = tool(named: "Selection", in: control)
        cursor.tap()
        assertSelection(cursor, control: control)
        XCTAssertFalse(tool(named: "Laser", in: control).exists)
        menu.tap()
        XCTAssertTrue(app.buttons["Mermaid to Excalidraw"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Math"].exists)
        XCTAssertTrue(app.buttons["Insert PDF"].exists)
        // The preserved simulator order places Laser after the nine visible tools.
        let laser = tool(named: "Laser", in: app)
        XCTAssertTrue(laser.exists, "Configured overflow tools and insert actions must share this menu")
        capture(app, name: "One menu contains configured overflow tools and insert actions")
        laser.tap()
        let noVisibleSelection = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                control.buttons.matching(NSPredicate(format: "isSelected == true")).count == 0
            }, object: control
        )
        XCTAssertEqual(XCTWaiter.wait(for: [noVisibleSelection], timeout: 3), .completed)
        XCTAssertTrue(control.exists)
        XCTAssertTrue((menu.value as? String)?.hasPrefix("Laser") == true)
        capture(app, name: "Closed combined menu shows the active overflow tool")
        menu.tap()
        waitForSelectedState(true, of: tool(named: "Laser", in: app))
        capture(app, name: "Combined menu confirms Laser selection")
    }

    private func waitForSelectedState(_ selected: Bool, of element: XCUIElement) {
        let state = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == %@", NSNumber(value: selected)), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 3), .completed)
    }

    private func drag(in canvas: XCUIElement, from start: CGVector, to end: CGVector) {
        canvas.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: end),
            withVelocity: .slow, thenHoldForDuration: 0.1
        )
    }

    private func capture(_ app: XCUIApplication, name: String) {
        // These artifacts require root's image inspection, not only a green XCTest result.
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func tool(named name: String, in control: XCUIElement) -> XCUIElement {
        control.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", name, "\(name) ("
        )).firstMatch
    }

    private func assertSelection(_ index: Int, control: XCUIElement) {
        assertSelection(control.buttons.element(boundBy: index), control: control)
    }

    private func assertSelection(_ button: XCUIElement, control: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: button
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        for other in control.buttons.allElementsBoundByIndex where other.label != button.label {
            XCTAssertFalse(other.isSelected)
        }
    }

    private func openSyntheticDrawing() -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AIChat.isEnabled", "NO", "-DisableCloudSync", "YES",
            "-WhatsNewLastBuild", "999999"
        ]
        launchedApp = app
        app.launch()

        let whatsNew = app.navigationBars.matching(
            NSPredicate(format: "identifier IN %@", ["What's New", "What’s New in ExcalidrawZ"])
        ).firstMatch
        if whatsNew.waitForExistence(timeout: 5) {
            whatsNew.buttons.firstMatch.tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: whatsNew
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }

        let newDrawing = app.buttons["New draw"].firstMatch
        let openedSidebar = !newDrawing.isHittable
        if openedSidebar {
            let showSidebar = app.navigationBars.buttons["Show Sidebar"].firstMatch
            guard showSidebar.waitForExistence(timeout: 5), showSidebar.isHittable else {
                captureSetupFailure(app, name: "Show Sidebar unavailable")
                XCTFail("The observed Show Sidebar button must be available before opening a new drawing")
                return app
            }
            showSidebar.tap()
        }
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: newDrawing
        )
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
            captureSetupFailure(app, name: "New draw unavailable after opening sidebar")
            XCTFail("New draw must be hittable after opening the sidebar")
            return app
        }
        newDrawing.tap()
        let hideSidebar = app.navigationBars.buttons["Hide Sidebar"].firstMatch
        if openedSidebar, hideSidebar.exists, hideSidebar.isHittable {
            hideSidebar.tap()
        }
        return app
    }

    private func captureSetupFailure(_ app: XCUIApplication, name: String) {
        capture(app, name: name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name), full accessibility tree"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
#endif
