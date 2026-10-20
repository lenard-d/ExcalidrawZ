#if os(iOS)
import XCTest

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
        let app = openFixture(compact: false)
        assertActions(in: app, width: 1024)
        assertInsertCallback(in: app)
    }

    func testNarrowLayoutKeepsActionsAboveScrollingContent() {
        let app = openFixture(compact: true)
        assertActions(in: app, width: 320)
        let insert = app.buttons["pdfInsert.confirm"]
        let initialFrame = insert.frame
        let viewerOption = app.buttons["pdfInsert.mode.viewer"]
        XCTAssertTrue(viewerOption.waitForExistence(timeout: 3))
        let initialOptionFrame = viewerOption.frame
        let viewport = app.otherElements["pdfFixture.viewport"]
        viewport.swipeUp()
        XCTAssertNotEqual(viewerOption.frame, initialOptionFrame, "The dialog content must actually scroll.")
        XCTAssertEqual(insert.frame, initialFrame, "Insert must stay fixed while content scrolls.")
        assertActions(in: app, width: 320)
        assertInsertCallback(in: app)
    }

    private func openFixture(compact: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-DisableCloudSync", "YES"]
        app.launchEnvironment["EXCALIDRAWZ_PDF_INSERT_UI_TEST"] = "1"
        app.launchEnvironment["EXCALIDRAWZ_PDF_INSERT_LAYOUT"] = compact ? "compact" : "wide"
        self.app = app
        app.launch()
        return app
    }

    private func assertActions(in app: XCUIApplication, width: CGFloat) {
        let viewport = app.otherElements["pdfFixture.viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 3))
        XCTAssertEqual(viewport.frame.width, width, accuracy: 1)
        XCTAssertEqual(viewport.frame.height, 768, accuracy: 1)
        for identifier in ["pdfInsert.confirm", "pdfInsert.cancel"] {
            let action = app.buttons[identifier]
            XCTAssertTrue(action.waitForExistence(timeout: 3), "Missing named action: \(identifier)")
            XCTAssertFalse(action.frame.isEmpty)
            XCTAssertTrue(viewport.frame.contains(action.frame), "Action must fit inside the fixture viewport.")
            XCTAssertTrue(action.isHittable)
        }
        XCTAssertTrue(app.buttons["pdfInsert.confirm"].isEnabled)
    }

    private func assertInsertCallback(in app: XCUIApplication) {
        let source = app.staticTexts["pdfFixture.sourceDigest"].label
        XCTAssertEqual(source.count, 64)
        app.buttons["pdfInsert.confirm"].tap()
        let callback = app.staticTexts["pdfFixture.callbackDigest"]
        let receivedData = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", source), object: callback)
        XCTAssertEqual(XCTWaiter.wait(for: [receivedData], timeout: 3), .completed)
        XCTAssertEqual(callback.label, source, "The named Insert action must deliver the exact synthetic PDF bytes.")
        XCTAssertEqual(app.staticTexts["pdfFixture.callbackOptions"].label, "viewer,vertical,1")
    }
}
#endif
