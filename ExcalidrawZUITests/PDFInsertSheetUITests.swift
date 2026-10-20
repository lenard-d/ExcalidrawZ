#if os(iOS)
import XCTest

/// Migrates PDFInsertSheetLayoutTests to the real app's public UI test surface.
@MainActor
final class PDFInsertSheetUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["EXCALIDRAWZ_ISOLATED_UI_TESTS"] == "1" else {
            throw NSError(domain: "PDFInsertSheetUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Run only with the audited isolated iOS simulator test configuration."
            ])
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    override func record(_ issue: XCTIssue) {
        if let app {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "PDF public UI fixture"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "PDF public accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        super.record(issue)
    }

    func testSelectedPDFHasReachableActionsInWideArea() {
        let app = openFixture("wide")
        assertActions(in: app, size: CGSize(width: 1024, height: 768))
        assertInsertCallback(in: app)
    }

    func testSelectedPDFHasReachableActionsInTallArea() {
        let app = openFixture("tall")
        assertActions(in: app, size: CGSize(width: 768, height: 1024))
        assertInsertCallback(in: app)
    }

    func testNarrowLayoutKeepsActionsAboveScrollingContent() {
        assertActionsAboveScrollingContent(scenario: "compact", width: 320)
    }

    func testAccessibilityLayoutKeepsActionsAboveScrollingContent() {
        assertActionsAboveScrollingContent(scenario: "accessibility", width: 1024)
    }

    func testNarrowAccessibilityLayoutKeepsActionsAboveScrollingContent() {
        assertActionsAboveScrollingContent(scenario: "narrowAccessibility", width: 320)
    }

    func testShortRegularLayoutKeepsTiledSettingsUsable() {
        let app = openFixture("shortRegular")
        let size = CGSize(width: 1024, height: 320)
        assertActions(in: app, size: size)
        let insertFrame = app.buttons["pdfInsert.confirm"].frame
        let settings = app.scrollViews.containing(.button, identifier: "pdfInsert.mode.viewer").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        let tiled = app.buttons["pdfInsert.mode.tiled"]
        scrollToVisible(tiled, in: settings)
        tiled.tap()

        let stepper = app.steppers["pdfInsert.itemsPerLine"]
        let increment = stepper.buttons["pdfInsert.itemsPerLine-Increment"]
        scrollToVisible(increment, in: settings)
        XCTAssertTrue(stepper.exists)
        XCTAssertTrue(settings.frame.contains(increment.frame), "The settings scroll must expose the stepper.")
        increment.tap()
        XCTAssertEqual(app.buttons["pdfInsert.confirm"].frame, insertFrame)
        assertActions(in: app, size: size)
        assertInsertCallback(in: app, options: "tiled,vertical,2")
    }

    func testCancelDismissesPresentedSheetWithoutInserting() {
        let app = openFixture("cancel")
        assertNamedActions(in: app, bounds: app.frame)
        app.buttons["pdfInsert.cancel"].tap()
        assertLabel("pdfFixture.presentation", equals: "dismissed", in: app)
        XCTAssertFalse(app.buttons["pdfInsert.confirm"].exists)
        XCTAssertFalse(app.buttons["pdfInsert.cancel"].exists)
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackCount"].label, "0")
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackDigest"].label, "none")
    }

    func testSuccessfulInsertDismissesPresentedSheet() {
        let app = openFixture("success")
        assertNamedActions(in: app, bounds: app.frame)
        app.buttons["pdfInsert.confirm"].tap()
        assertLabel("pdfFixture.presentation", equals: "dismissed", in: app)
        XCTAssertFalse(app.buttons["pdfInsert.confirm"].exists)
        XCTAssertFalse(app.buttons["pdfInsert.cancel"].exists)
        assertCallback(in: app, count: 1, options: "viewer,vertical,1")
    }

    func testInsertIsDisabledWithoutASelectedPDF() {
        let app = openFixture("empty")
        assertActions(in: app, size: CGSize(width: 1024, height: 768), insertEnabled: false)
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackCount"].label, "0")
    }

    func testFailedInsertKeepsPDFAndEnablesRetryAfterLoading() {
        let app = openFixture("retry")
        let size = CGSize(width: 320, height: 768)
        assertActions(in: app, size: size)
        for attempt in 1...2 {
            app.buttons["pdfInsert.confirm"].tap()
            assertLabel("pdfFixture.callbackCount", equals: String(attempt), in: app)
            assertCallback(in: app, count: attempt, options: "viewer,vertical,1")
            assertActions(in: app, size: size, insertEnabled: false)
            let failPending = app.buttons["pdfFixture.failPendingInsert"]
            XCTAssertTrue(failPending.isEnabled, "The callback must remain pending until the fixture completes it.")
            XCTAssertTrue(failPending.isHittable)
            failPending.tap()
            assertEnabled(app.buttons["pdfInsert.confirm"])
            let error = app.staticTexts["pdfInsert.error"]
            XCTAssertTrue(error.waitForExistence(timeout: 3))
            XCTAssertEqual(error.label, "Failed to load PDF: Synthetic insert failure")
            XCTAssertTrue(app.otherElements["pdfFixture.viewport"].frame.contains(error.frame))
            XCTAssertTrue(error.isHittable)
            assertActions(in: app, size: size)
        }
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackCount"].label, "2")
        XCTAssertEqual(app.staticTexts["pdfFixture.presentation"].label, "presented")
    }

    private func assertActionsAboveScrollingContent(scenario: String, width: CGFloat) {
        let app = openFixture(scenario)
        let size = CGSize(width: width, height: 768)
        assertActions(in: app, size: size)
        let initialInsertFrame = app.buttons["pdfInsert.confirm"].frame
        let viewerOption = app.buttons["pdfInsert.mode.viewer"]
        XCTAssertTrue(viewerOption.waitForExistence(timeout: 3))
        let initialOptionFrame = viewerOption.frame
        let viewport = app.otherElements["pdfFixture.viewport"]
        XCTAssertTrue(viewport.frame.intersects(initialOptionFrame), "The scroll marker must start in the viewport.")
        viewport.swipeUp()
        // Form can remove the previously visible row from the public hierarchy.
        let didScroll = !viewerOption.exists || viewerOption.frame != initialOptionFrame
        XCTAssertTrue(didScroll, "The mode row must move or leave the viewport after scrolling.")
        XCTAssertEqual(app.buttons["pdfInsert.confirm"].frame, initialInsertFrame, "Insert must stay fixed while content scrolls.")
        assertActions(in: app, size: size)
        assertInsertCallback(in: app)
    }

    private func openFixture(_ scenario: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DisableCloudSync", "YES"]
        app.launchEnvironment["EXCALIDRAWZ_PDF_INSERT_UI_TEST"] = "1"
        app.launchEnvironment["EXCALIDRAWZ_PDF_INSERT_LAYOUT"] = scenario
        self.app = app
        app.launch()
        return app
    }

    private func assertActions(in app: XCUIApplication, size: CGSize, insertEnabled: Bool = true) {
        let viewport = app.otherElements["pdfFixture.viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 3))
        XCTAssertEqual(viewport.frame.width, size.width, accuracy: 1)
        XCTAssertEqual(viewport.frame.height, size.height, accuracy: 1)
        XCTAssertTrue(app.frame.contains(viewport.frame), "The fixed viewport must fit in the actual host window.")
        assertNamedActions(in: app, bounds: viewport.frame, insertEnabled: insertEnabled)
    }

    private func assertNamedActions(in app: XCUIApplication, bounds: CGRect, insertEnabled: Bool = true) {
        for identifier in ["pdfInsert.confirm", "pdfInsert.cancel"] {
            let action = app.buttons[identifier]
            XCTAssertTrue(action.waitForExistence(timeout: 3), "Missing named action: \(identifier)")
            XCTAssertFalse(action.frame.isEmpty)
            XCTAssertTrue(bounds.contains(action.frame), "Action must fit inside the available area.")
            XCTAssertTrue(action.isHittable)
        }
        XCTAssertEqual(app.buttons["pdfInsert.confirm"].isEnabled, insertEnabled)
        XCTAssertTrue(app.buttons["pdfInsert.cancel"].isEnabled)
    }

    private func assertInsertCallback(in app: XCUIApplication, options: String = "viewer,vertical,1") {
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackCount"].label, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Selected PDF with reachable Insert and Cancel"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["pdfInsert.confirm"].tap()
        assertCallback(in: app, count: 1, options: options)
    }

    private func assertCallback(in app: XCUIApplication, count: Int, options: String) {
        let source = app.staticTexts["pdfFixture.sourceDigest"].label
        XCTAssertEqual(source.count, 64)
        XCTAssertEqual(app.staticTexts["pdfFixture.sourcePageCount"].label, "4")
        assertLabel("pdfFixture.callbackCount", equals: String(count), in: app)
        assertLabel("pdfFixture.callbackDigest", equals: source, in: app)
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackDigest"].label, source,
                       "The named Insert action must deliver the exact synthetic PDF bytes.")
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackOptions"].label, options)
    }

    private func assertLabel(_ identifier: String, equals expected: String, in app: XCUIApplication) {
        let label = app.staticTexts[identifier]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed, "Expected \(identifier) to report \(expected).")
    }

    private func assertEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    private func scrollToVisible(_ element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { break }
            scrollView.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "The named settings control must be reachable by scrolling.")
    }
}
#endif
