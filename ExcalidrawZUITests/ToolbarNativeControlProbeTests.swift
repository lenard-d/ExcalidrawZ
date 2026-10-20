import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit

final class ToolbarNativeControlProbeTests: XCTestCase {
    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["EXCALIDRAWZ_ISOLATED_UI_TESTS"] == "1" else {
            throw XCTSkip("Root must inspect the isolated simulator app identity and data paths first.")
        }
    }

    override func tearDownWithError() throws {
        launchedApp?.terminate()
        launchedApp = nil
        XCUIDevice.shared.orientation = .portrait
    }

    func testSegmentedControlQuickTapsAndBothDragDirections() {
        compareNativeControl("segmented")
    }

    func testTabBarQuickTapsAndBothDragDirections() {
        compareNativeControl("tabbar")
    }

    private func compareNativeControl(_ kind: String) {
        let app = openSyntheticDrawing(kind: kind)
        let control = app.descendants(matching: .any)["toolbarNativeControlProbe.control"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        XCTAssertTrue(control.isHittable)
        let trace = app.staticTexts["toolbarNativeControlProbe.trace"]
        XCTAssertTrue(trace.waitForExistence(timeout: 5))

        for number in [3, 1, 2] {
            point(in: control, number: number).tap()
            assertSelection(number, trace: trace)
        }

        point(in: control, number: 1).press(
            forDuration: 0.3,
            thenDragTo: point(in: control, number: 3),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        assertSelection(3, trace: trace)
        point(in: control, number: 3).press(
            forDuration: 0.3,
            thenDragTo: point(in: control, number: 1),
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        assertSelection(1, trace: trace)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(kind) after taps and forward-reverse drag"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Root records video to inspect the visible preview while the finger moves.
        // A callback only on release is sufficient for the final-selection checks.
    }

    private func point(in control: XCUIElement, number: Int) -> XCUICoordinate {
        control.coordinate(withNormalizedOffset: CGVector(dx: (Double(number) - 0.5) / 3, dy: 0.5))
    }

    private func assertSelection(_ number: Int, trace: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "selected=\(number);"),
            object: trace
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
    }

    private func openSyntheticDrawing(kind: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["EXCALIDRAWZ_TOOLBAR_NATIVE_PROBE"] = kind
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
