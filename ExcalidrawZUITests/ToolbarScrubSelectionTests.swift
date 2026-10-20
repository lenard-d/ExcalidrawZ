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
        control.buttons.element(boundBy: 2).tap()
        assertSelection(2, control: control)
        drag(in: canvas, from: CGVector(dx: 0.25, dy: 0.35), to: CGVector(dx: 0.40, dy: 0.55))
        capture(app, name: "Canvas diamond after quick tap, inspect actual shape")

        let first = control.buttons.element(boundBy: 0)
        let sixth = control.buttons.element(boundBy: 5)
        first.press(forDuration: 0.3, thenDragTo: sixth, withVelocity: .slow, thenHoldForDuration: 0.3)
        assertSelection(5, control: control)
        drag(in: canvas, from: CGVector(dx: 0.55, dy: 0.35), to: CGVector(dx: 0.75, dy: 0.55))
        capture(app, name: "Canvas line after forward scrub, inspect actual line")

        sixth.press(forDuration: 0.3, thenDragTo: first, withVelocity: .slow, thenHoldForDuration: 0.3)
        assertSelection(0, control: control)
        drag(in: canvas, from: CGVector(dx: 0.20, dy: 0.30), to: CGVector(dx: 0.45, dy: 0.60))
        capture(app, name: "Canvas diamond selection after reverse scrub, inspect selection handles")

        // Start at the former divider between the second and third tools.
        let second = control.buttons.element(boundBy: 1)
        let boundary = control.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: second.frame.maxX - control.frame.minX, dy: control.frame.height / 2)
        )
        boundary.press(forDuration: 0.3, thenDragTo: sixth.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        assertSelection(5, control: control)
        sixth.tap()
        assertSelection(5, control: control)

        capture(app, name: "Real configured tools after quick taps and forward-reverse scrub")
        // Root records video to verify the native selection preview during the drag.
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

    private func assertSelection(_ index: Int, control: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"),
            object: control.buttons.element(boundBy: index)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        for other in 0..<control.buttons.count where other != index {
            XCTAssertFalse(control.buttons.element(boundBy: other).isSelected)
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
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: newDrawing
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        newDrawing.tap()
        return app
    }
}
#endif
