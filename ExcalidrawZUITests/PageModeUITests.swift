import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit

final class PageModeUITests: XCTestCase {
    private var launchedApp: XCUIApplication?
    private var originalOrientation: UIDeviceOrientation = .unknown

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["EXCALIDRAWZ_ISOLATED_UI_TESTS"] == "1" else {
            throw NSError(domain: "PageModeUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Root must audit the isolated simulator identity and data paths before this test."
            ])
        }
        originalOrientation = XCUIDevice.shared.orientation
    }

    override func tearDownWithError() throws {
        launchedApp?.terminate()
        launchedApp = nil
        if originalOrientation != .unknown { XCUIDevice.shared.orientation = originalOrientation }
    }

    func testSyntheticPageWritingFeedback() throws {
        let app = try openSyntheticDrawing()
        try openPages(in: app)
        let add = app.buttons["pages.add"].firstMatch
        try requireHittable(add, in: app, step: "Create a tagged page for writing feedback")
        add.tap()
        let canvas = app.webViews.firstMatch
        try requireHittable(canvas, in: app, step: "Synthetic page canvas")
        try requireHittable(pageHeader("Page 1", in: app), in: app, step: "Tagged page before drawing")
        capture(app, step: "Tagged page before writing")
        try selectTool("Diamond", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
            .press(forDuration: 0.1,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60)),
                   withVelocity: .slow, thenHoldForDuration: 3)
        capture(app, step: "Tagged page after writing, inspect video for blue border during contact")
    }

    func testSyntheticPageContextLayoutsAndBothAddDirections() throws {
        let app = try openSyntheticDrawing()
        let canvas = app.webViews.firstMatch
        try requireHittable(canvas, in: app, step: "New synthetic canvas")
        try openPages(in: app)
        let add = app.buttons["pages.add"].firstMatch
        try requireHittable(add, in: app, step: "First page through normal Pages sheet")
        add.tap()

        try selectTool("Selection", in: app)
        try selectPage("Page 1", in: app)
        try assertContext(in: app, page: "Page 1", step: "Normal landscape page header")
        try setLayout("Grid", in: app)

        // Root records this held contact and inspects the frame feedback and actual ink.
        try selectTool("Diamond", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.50))
            .press(forDuration: 0.1,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.65)),
                   withVelocity: .slow, thenHoldForDuration: 3)
        capture(app, step: "Synthetic grid page after held drawing contact, inspect ink and blue feedback")
        try selectTool("Selection", in: app)
        try selectPage("Page 1", in: app)
        try setLayout("Ruled", in: app)
        capture(app, step: "Ruled layout after grid, inspect that the diamond remains")

        try addPage("Add below", in: app)
        try selectPage("Page 2", in: app)
        try assertLayout("Ruled", in: app)
        try addPage("Add right", in: app)
        try selectPage("Page 3", in: app)
        try assertLayout("Ruled", in: app)

        try openPages(in: app)
        XCTAssertTrue(app.buttons["pages.open.2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pages.open.3"].exists)
        let overview = app.buttons["Canvas"].firstMatch
        try requireHittable(overview, in: app, step: "Page overview")
        overview.tap()
        let first = pageHeader("Page 1", in: app)
        let second = pageHeader("Page 2", in: app)
        let third = pageHeader("Page 3", in: app)
        for header in [first, second, third] {
            try requireHittable(header, in: app, step: "All page headers after zoom to canvas")
        }
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 10)
        XCTAssertGreaterThan(second.frame.minY, first.frame.maxY)
        XCTAssertGreaterThan(third.frame.minX, second.frame.maxX)
        XCTAssertEqual(second.frame.minY, third.frame.minY, accuracy: 10)
        third.tap()
        try assertContext(in: app, page: "Page 3", step: "Zoomed-out selected page header")
        capture(app, step: "Overview, inspect below-right positions, separate layouts and retained first-page ink")

        XCUIDevice.shared.orientation = .portrait
        try openPages(in: app)
        let openThird = app.buttons["pages.open.2"].firstMatch
        try requireHittable(openThird, in: app, step: "Open third page in portrait")
        openThird.tap()
        try selectPage("Page 3", in: app)
        try assertContext(in: app, page: "Page 3", step: "Portrait selected page header")
        try assertLayout("Ruled", in: app)
    }

    /// Captures actual canvas handles before a resize route can use their screen positions.
    func testCaptureSyntheticPageResizeHandles() throws {
        let app = try openSyntheticDrawing()
        try selectTool("Selection", in: app)
        try openPages(in: app)
        let add = app.buttons["pages.add"].firstMatch
        try requireHittable(add, in: app, step: "Create a fresh page for resize capture")
        add.tap()
        try selectPage("Page 1", in: app)
        try setLayout("Grid", in: app)
        try assertContext(in: app, page: "Page 1", step: "Resize capture: normal Grid page and handles")
        try setLayout("Ruled", in: app)
        capture(app, step: "Resize capture: normal Ruled page and handles")

        try addPage("Add right", in: app)
        try openPages(in: app)
        let overview = app.buttons["Canvas"].firstMatch
        try requireHittable(overview, in: app, step: "Resize capture: public canvas overview")
        overview.tap()
        try selectPage("Page 1", in: app)
        try assertContext(in: app, page: "Page 1", step: "Resize capture: overview top handle and controls")
        // Canvas handles have no accessibility element. Root must inspect these captures
        // before supplying a drag route. This test does not claim a resize passed.
    }

    func testSyntheticPageNativeResizeAndUndo() throws {
        let app = try openSyntheticDrawing()
        try selectTool("Selection", in: app)
        try openPages(in: app)
        let add = app.buttons["pages.add"].firstMatch
        try requireHittable(add, in: app, step: "Create a fresh page for native resize")
        add.tap()
        try selectPage("Page 1", in: app)
        try setLayout("Grid", in: app)
        try requireObservedResizeAnchor(in: app, overview: false)

        try selectTool("Diamond", in: app)
        try drag(from: CGPoint(x: 700, y: 400), to: CGPoint(x: 800, y: 500), in: app)
        try selectTool("Selection", in: app)
        try selectPage("Page 1", in: app)

        for layout in ["Grid", "Ruled"] {
            try setLayout(layout, in: app)
            try requireObservedResizeAnchor(in: app, overview: false)
            let header = pageHeader("Page 1", in: app).frame
            let right = app.buttons["pages.context.add"].firstMatch.frame.maxX
            capture(app, step: "\(layout) before proportional corner resize, retain the Diamond")

            // Observed normal selected-frame NE handle, pages-resize4ca-grid40.png.
            try drag(from: CGPoint(x: 1148, y: 106), to: CGPoint(x: 1078, y: 206), in: app)
            try waitForResize(in: app, step: "\(layout) proportional corner moved") {
                self.pageHeader("Page 1", in: app).frame.minY > header.minY + 50 &&
                    app.buttons["pages.context.add"].firstMatch.frame.maxX < right - 40
            }
            let heightChange = pageHeader("Page 1", in: app).frame.minY - header.minY
            let widthChange = right - app.buttons["pages.context.add"].firstMatch.frame.maxX
            XCTAssertEqual(widthChange / heightChange, 595.0 / 842.0, accuracy: 0.04)
            capture(app, step: "\(layout) proportional resize, inspect full paper and unchanged Diamond")
            try undoResize(in: app)
            try requireObservedResizeAnchor(in: app, overview: false)

            // The right-side handle is visible at the page's mid-height in that capture.
            try drag(from: CGPoint(x: 1148, y: 555), to: CGPoint(x: 1048, y: 555), in: app)
            try waitForResize(in: app, step: "\(layout) free right edge moved") {
                abs(app.buttons["pages.context.add"].firstMatch.frame.maxX - (right - 100)) < 4
            }
            XCTAssertEqual(pageHeader("Page 1", in: app).frame.minY, header.minY, accuracy: 3)
            capture(app, step: "\(layout) free width resize, inspect full paper and unchanged height and ink")
            try drag(from: CGPoint(x: 1048, y: 555), to: CGPoint(x: 1088, y: 555), in: app)
            try waitForResize(in: app, step: "\(layout) repeated free resize moved") {
                abs(app.buttons["pages.context.add"].firstMatch.frame.maxX - (right - 60)) < 4
            }
            capture(app, step: "\(layout) repeated resize after pointer release, inspect paper and ink")
            try undoResize(in: app)
            try waitForResize(in: app, step: "\(layout) undo repeated edge resize") {
                abs(app.buttons["pages.context.add"].firstMatch.frame.maxX - (right - 100)) < 4
            }
            try undoResize(in: app)
            try requireObservedResizeAnchor(in: app, overview: false)
            try assertLayout(layout, in: app)
            capture(app, step: "\(layout) undo restores original paper extent and Diamond")
        }

        try addPage("Add right", in: app)
        try openPages(in: app)
        let overview = app.buttons["Canvas"].firstMatch
        try requireHittable(overview, in: app, step: "Overview for actual top-edge clearance")
        overview.tap()
        try selectPage("Page 1", in: app)
        try requireObservedResizeAnchor(in: app, overview: true)
        let headerY = pageHeader("Page 1", in: app).frame.minY
        let right = app.buttons["pages.context.add"].firstMatch.frame.maxX
        // Observed overview top-side handle, pages-resize4ca-overview64.png.
        try drag(from: CGPoint(x: 604, y: 232), to: CGPoint(x: 604, y: 272), in: app)
        try waitForResize(in: app, step: "Overview top handle resizes instead of opening a control") {
            abs(self.pageHeader("Page 1", in: app).frame.minY - (headerY + 40)) < 4
        }
        XCTAssertEqual(app.buttons["pages.context.add"].firstMatch.frame.maxX, right, accuracy: 3)
        try drag(from: CGPoint(x: 604, y: 272), to: CGPoint(x: 604, y: 252), in: app)
        try waitForResize(in: app, step: "Overview repeated top resize") {
            abs(self.pageHeader("Page 1", in: app).frame.minY - (headerY + 20)) < 4
        }
        capture(app, step: "Overview repeated free top resize, controls remain separate from handle")
        try undoResize(in: app)
        try waitForResize(in: app, step: "Overview first top-edge undo") {
            abs(self.pageHeader("Page 1", in: app).frame.minY - (headerY + 40)) < 4
        }
        try undoResize(in: app)
        try requireObservedResizeAnchor(in: app, overview: true)
        capture(app, step: "Overview undo restores page and paper; second page stays unchanged")
    }

    private func requireObservedResizeAnchor(in app: XCUIApplication, overview: Bool) throws {
        try assertContext(in: app, page: "Page 1", step: overview ? "Overview resize anchor" : "Normal resize anchor")
        let expectedHeader = overview ? CGPoint(x: 378, y: 214) : CGPoint(x: 513, y: 89)
        let expectedRight: CGFloat = overview ? 805.5 : 1118.5
        let header = pageHeader("Page 1", in: app).frame
        let controls = [app.buttons["pages.context.layout"].firstMatch.frame,
                        app.buttons["pages.context.add"].firstMatch.frame]
        guard abs(header.minX - expectedHeader.x) < 3,
              abs(header.minY - expectedHeader.y) < 3,
              abs(controls[1].maxX - expectedRight) < 3,
              abs(app.frame.width - 1366) < 1, abs(app.frame.height - 1024) < 1 else {
            capture(app, step: "STOP: selected-page geometry differs from inspected resize captures")
            throw NSError(domain: "PageModeUITests", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Inspect current selected-frame handles before changing resize coordinates."
            ])
        }
        let topCenter = overview ? CGPoint(x: 604, y: 232) : CGPoint(x: 828.5, y: 106)
        let topRight = overview ? CGPoint(x: 834, y: 232) : CGPoint(x: 1148, y: 106)
        for center in [topCenter, topRight] {
            let touchArea = CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
            for control in controls { XCTAssertFalse(control.intersects(touchArea)) }
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint, in app: XCUIApplication) throws {
        let canvas = app.webViews.firstMatch
        try requireHittable(canvas, in: app, step: "Public canvas for observed resize geometry")
        guard canvas.frame.contains(start), canvas.frame.contains(end) else {
            capture(app, step: "STOP: observed drag is outside the current canvas")
            throw NSError(domain: "PageModeUITests", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "The current canvas does not contain the inspected drag route."
            ])
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: start.x, dy: start.y))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func undoResize(in app: XCUIApplication) throws {
        let undo = app.buttons["toolbar.undo"].firstMatch
        try requireHittable(undo, in: app, step: "Undo the last public resize")
        undo.tap()
    }

    private func waitForResize(in app: XCUIApplication, step: String, condition: @escaping () -> Bool) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [changed], timeout: 5) == .completed else {
            capture(app, step: "STOP: \(step)")
            throw NSError(domain: "PageModeUITests", code: 7, userInfo: [NSLocalizedDescriptionKey: step])
        }
    }

    private func openSyntheticDrawing() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AIChat.isEnabled", "NO", "-DisableCloudSync", "YES",
            "-WhatsNewLastBuild", "999999"
        ]
        launchedApp = app
        app.launch()
        let whatsNew = app.navigationBars.matching(NSPredicate(
            format: "identifier IN %@", ["What's New", "What’s New in ExcalidrawZ"]
        )).firstMatch
        if whatsNew.waitForExistence(timeout: 5) {
            whatsNew.buttons.firstMatch.tap()
        }
        let newDrawing = app.buttons["New draw"].firstMatch
        let openedSidebar = !newDrawing.isHittable
        let sidebar = app.buttons["Show Sidebar"].firstMatch
        if openedSidebar {
            try requireHittable(sidebar, in: app, step: "Show the sidebar to create a new drawing")
            sidebar.tap()
        }
        try requireHittable(newDrawing, in: app, step: "Create a new drawing without opening existing drawings")
        newDrawing.tap()
        if openedSidebar, newDrawing.isHittable {
            let hideSidebar = app.buttons["Hide Sidebar"].firstMatch
            try requireHittable(hideSidebar, in: app, step: "Restore the hidden sidebar after creating the drawing")
            hideSidebar.tap()
        }
        return app
    }

    private func openPages(in app: XCUIApplication) throws {
        let extraTools = app.buttons["toolbar.extraTools"].firstMatch
        let menu = extraTools.exists ? extraTools : app.buttons["toolbar.moreTools"].firstMatch
        try requireHittable(menu, in: app, step: "Public tool actions menu")
        menu.tap()
        let pages = app.buttons["Pages"].firstMatch
        let actions = app.collectionViews.containing(.button, identifier: "Pages").firstMatch
        for _ in 0..<3 {
            if pages.isHittable { break }
            try requireHittable(actions, in: app, step: "Open menu containing Pages")
            actions.swipeUp(velocity: .slow)
        }
        try requireHittable(pages, in: app, step: "Public Pages action")
        capture(app, step: "Pages action after bounded public menu scroll")
        pages.tap()
    }

    private func selectTool(_ name: String, in app: XCUIApplication) throws {
        let predicate = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + " (")
        let visible = app.segmentedControls["toolbar.toolPicker"].buttons.matching(predicate).firstMatch
        if visible.exists && visible.isHittable {
            visible.tap()
            return
        }
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        try requireHittable(menu, in: app, step: "Tool overflow for \(name)")
        menu.tap()
        let overflow = app.buttons.matching(predicate).firstMatch
        try requireHittable(overflow, in: app, step: "Public \(name) tool")
        overflow.tap()
    }

    private func pageHeader(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.firstMatch.staticTexts[title].firstMatch
    }

    private func selectPage(_ title: String, in app: XCUIApplication) throws {
        let header = pageHeader(title, in: app)
        try requireHittable(header, in: app, step: "Select actual \(title) header")
        guard !app.navigationBars.allElementsBoundByIndex.contains(where: { $0.frame.intersects(header.frame) }) else {
            capture(app, step: "STOP: \(title) header covered by navigation")
            throw NSError(domain: "PageModeUITests", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The page header is behind the native navigation area."
            ])
        }
        header.tap()
    }

    private func setLayout(_ title: String, in app: XCUIApplication) throws {
        let menu = app.buttons["pages.context.layout"].firstMatch
        try requireHittable(menu, in: app, step: "Context layout menu")
        menu.tap()
        let option = app.buttons[title].firstMatch
        try requireHittable(option, in: app, step: "Choose \(title) layout")
        option.tap()
        try assertLayout(title, in: app)
    }

    private func assertLayout(_ title: String, in app: XCUIApplication) throws {
        let menu = app.buttons["pages.context.layout"].firstMatch
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: menu)
        guard XCTWaiter.wait(for: [changed], timeout: 5) == .completed else {
            capture(app, step: "Expected persisted layout \(title)")
            throw NSError(domain: "PageModeUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Layout value did not become \(title)."])
        }
    }

    private func addPage(_ direction: String, in app: XCUIApplication) throws {
        let menu = app.buttons["pages.context.add"].firstMatch
        try requireHittable(menu, in: app, step: "Selected-page New page action")
        menu.tap()
        for title in ["Add below", "Add right"] {
            try requireHittable(app.buttons[title].firstMatch, in: app, step: "Both placement choices")
        }
        app.buttons[direction].firstMatch.tap()
    }

    private func assertContext(in app: XCUIApplication, page: String, step: String) throws {
        let add = app.buttons["pages.context.add"].firstMatch
        let layout = app.buttons["pages.context.layout"].firstMatch
        try requireHittable(add, in: app, step: step)
        try requireHittable(layout, in: app, step: step)
        let canvas = app.webViews.firstMatch.frame
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        XCTAssertGreaterThanOrEqual(layout.frame.height, 44)
        XCTAssertTrue(canvas.contains(add.frame))
        XCTAssertTrue(canvas.contains(layout.frame))
        XCTAssertLessThan(abs(add.frame.midY - pageHeader(page, in: app).frame.midY), 110)
        capture(app, step: step)
    }

    private func requireHittable(_ element: XCUIElement, in app: XCUIApplication, step: String) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: element)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            capture(app, step: "STOP: \(step)")
            throw NSError(domain: "PageModeUITests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Public UI element unavailable at: \(step). Inspect the attached tree and screenshot before changing the route."])
        }
    }

    private func capture(_ app: XCUIApplication, step: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = step
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = step + " accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
#endif
