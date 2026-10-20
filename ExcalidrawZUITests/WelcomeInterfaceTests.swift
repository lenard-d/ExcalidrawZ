import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit

final class WelcomeInterfaceTests: XCTestCase {
    private var launchedApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["EXCALIDRAWZ_ISOLATED_UI_TESTS"] == "1" else {
            throw XCTSkip("Run only in a fresh simulator with inspected test identities and data paths.")
        }
    }

    override func tearDownWithError() throws {
        if let launchedApp {
            launchedApp.terminate()
            XCUIDevice.shared.orientation = .portrait
            self.launchedApp = nil
        }
    }

    func testCancelConsentKeepsAIWelcomeAndRequiresConsentAgain() {
        let app = openWelcome(orientation: .landscapeLeft)
        let primaryAction = app.buttons["aiChatWelcomePrimaryAction"]
        XCTAssertTrue(primaryAction.isHittable)

        primaryAction.tap()
        assertConsentIsRequired(in: app)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send message"].exists)
        primaryAction.tap()
        assertConsentIsRequired(in: app)
    }

    func testLargeTextCanScrollDetailsAndReturnToActionInBothOrientations() {
        let app = openWelcome(orientation: .landscapeLeft, largeText: true)
        let scrollView = app.scrollViews["aiChatWelcomeScrollView"]
        let primaryAction = app.buttons["aiChatWelcomePrimaryAction"]
        let details = app.buttons["aiChatWelcomeDetails"]

        scrollToHittable(details, in: scrollView, towardBottom: true)
        details.tap()

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let lastFeature = scrollView.staticTexts
                .matching(NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "Revert any turn",
                    "Every AI edit is checkpointed — roll back instantly if you don't like it."
                ))
                .firstMatch
            scrollToReadableContent(lastFeature, in: scrollView, app: app)

            scrollToHittable(primaryAction, in: scrollView, towardBottom: false)
            XCTAssertTrue(primaryAction.isHittable)
            primaryAction.tap()
            assertConsentIsRequired(in: app)
            // The normal-size test covers Cancel. Use native sheet dismissal here.
            app.swipeDown()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: app.buttons["Enable AI"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            XCTAssertTrue(primaryAction.isHittable)
            XCTAssertFalse(app.buttons["Send message"].exists)
        }
    }

    func testPresentationWelcomePlanAndActionRemainReachableAtLargeText() {
        let app = launchApp(
            orientation: .landscapeLeft,
            largeText: true,
            presentationWelcomeFixture: true
        )

        let scrollView = app.scrollViews["presentationWelcomeScrollView"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
        let planCaption = app.staticTexts["presentationWelcomePlanCaption"]
        let primaryAction = app.buttons["presentationWelcomePrimaryAction"]

        for (index, orientation) in [UIDeviceOrientation.landscapeLeft, .portrait].enumerated() {
            XCUIDevice.shared.orientation = orientation
            scrollToReadableContent(planCaption, in: scrollView, app: app)
            scrollToHittable(primaryAction, in: scrollView, towardBottom: false)
            XCTAssertTrue(primaryAction.isHittable)
            primaryAction.tap()

            let result = app.alerts["Upgrade action received"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            XCTAssertTrue(result.staticTexts["Request \(index + 1)"].exists)
            result.buttons["OK"].tap()
            XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        }
    }

    private func openWelcome(
        orientation: UIDeviceOrientation,
        largeText: Bool = false
    ) -> XCUIApplication {
        let app = openDrawing(orientation: orientation, largeText: largeText)
        let welcome = app.scrollViews["aiChatWelcomeScrollView"]
        if !welcome.waitForExistence(timeout: 2) {
            let chat = app.buttons["AI Chat"].firstMatch
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"),
                object: chat
            )
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            chat.tap()
        }
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["aiChatWelcomePrimaryAction"].waitForExistence(timeout: 5))
        return app
    }

    private func openDrawing(
        orientation: UIDeviceOrientation,
        largeText: Bool = false
    ) -> XCUIApplication {
        let app = launchApp(orientation: orientation, largeText: largeText)
        dismissStartupSheet(in: app)

        let newDrawing = app.buttons["New draw"].firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: newDrawing
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        newDrawing.tap()
        return app
    }

    private func launchApp(
        orientation: UIDeviceOrientation,
        largeText: Bool,
        presentationWelcomeFixture: Bool = false
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-AIChat.isEnabled", "NO",
            "-DisableCloudSync", "YES",
            "-WhatsNewLastBuild", "999999"
        ]
        if largeText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        if presentationWelcomeFixture {
            app.launchEnvironment["EXCALIDRAWZ_PRESENTATION_WELCOME_FIXTURE"] = "1"
        }
        launchedApp = app
        app.launch()
        return app
    }

    private func dismissStartupSheet(in app: XCUIApplication) {
        // Debug builds show What's New even when WhatsNewLastBuild is current.
        let whatsNew = app.navigationBars.matching(
            NSPredicate(format: "identifier IN %@", ["What's New", "What’s New in ExcalidrawZ"])
        ).firstMatch
        if whatsNew.waitForExistence(timeout: 5) {
            whatsNew.buttons.firstMatch.tap()
            let dismissed = NSPredicate(format: "exists == false")
            expectation(for: dismissed, evaluatedWith: whatsNew)
            waitForExpectations(timeout: 5)
        }
    }

    private func assertConsentIsRequired(in app: XCUIApplication) {
        let enable = app.buttons["Enable AI"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertFalse(enable.isEnabled)
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        towardBottom: Bool
    ) {
        for _ in 0..<8 {
            if element.isHittable { return }
            if towardBottom {
                scrollView.swipeUp()
            } else {
                scrollView.swipeDown()
            }
        }
        XCTAssertTrue(element.isHittable, "Welcome content must remain reachable by scrolling.")
    }

    private func scrollToReadableContent(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        app: XCUIApplication
    ) {
        // Static text can be readable without providing an XCTest hit point.
        func isFullyVisible() -> Bool {
            guard element.exists else { return false }
            let frame = element.frame
            let viewport = scrollView.frame.intersection(app.windows.firstMatch.frame)
            return !frame.isEmpty && !viewport.isEmpty
                && viewport.insetBy(dx: -1, dy: -1).contains(frame)
        }

        for _ in 0..<8 {
            if isFullyVisible() { return }
            scrollView.swipeUp()
        }
        if !isFullyVisible() {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let elementFrame = element.exists ? "\(element.frame)" : "missing"
            XCTFail("The complete welcome text must fit inside the on-screen scroll viewport. Element: \(elementFrame), scroll view: \(scrollView.frame), window: \(app.windows.firstMatch.frame).")
        }
    }
}
#endif
