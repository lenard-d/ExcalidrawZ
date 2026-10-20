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

    func testExploreSyntheticDrawingTitleMenu() throws {
        let app = try openSyntheticDrawing()
        let more = app.navigationBars.buttons["More"].firstMatch
        try requireHittable(more, in: app, step: "Exact current synthetic drawing title menu")
        more.tap()
        capture(app, step: "STOP: current synthetic drawing title menu before rename")
        let rename = app.buttons["Rename"].firstMatch
        try requireHittable(rename, in: app, step: "Observed current drawing Rename action")
        rename.tap()
        capture(app, step: "STOP: current synthetic drawing Rename presentation")
    }

    func testExploreSyntheticPageDuplicateAndReopenRoute() throws {
        let app = try openSyntheticDrawing()
        let drawingName = "Pages-Duplicate-" + UUID().uuidString.prefix(8)
        let titleMenu = app.navigationBars.buttons["More"].firstMatch
        try requireHittable(titleMenu, in: app, step: "Rename only the new synthetic drawing")
        titleMenu.tap()
        let rename = app.buttons["Rename"].firstMatch
        try requireHittable(rename, in: app, step: "Observed Rename action")
        rename.tap()
        let nameField = app.textFields.firstMatch
        try requireHittable(nameField, in: app, step: "Observed drawing name field")
        XCTAssertEqual(app.textFields.count, 1)
        let oldName = try XCTUnwrap(nameField.value as? String)
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count) + drawingName)
        let confirmRename = app.buttons["OK"].firstMatch
        try requireHittable(confirmRename, in: app, step: "Observed Rename confirmation")
        confirmRename.tap()
        capture(app, step: "Unique synthetic drawing: " + drawingName)
        try selectTool("Rectangle", in: app)
        let rectangle = app.segmentedControls["toolbar.toolPicker"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rectangle")).firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: rectangle)
        guard XCTWaiter.wait(for: [selected], timeout: 10) == .completed else {
            capture(app, step: "STOP: new canvas did not confirm the public tool change")
            throw NSError(domain: "PageModeUITests", code: 5)
        }
        try selectTool("Selection", in: app)
        capture(app, step: "New canvas after confirmed public tool change")
        try openPages(in: app)
        let add = app.buttons["pages.add"].firstMatch
        try requireHittable(add, in: app, step: "Create the synthetic page to duplicate")
        add.tap()
        try selectTool("Selection", in: app)
        try selectPage("Page 1", in: app)
        try setLayout("Grid", in: app)

        let canvas = app.webViews.firstMatch
        try selectTool("Diamond", in: app)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
            .press(forDuration: 0.1,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.60)))
        try selectTool("Selection", in: app)
        try selectPage("Page 1", in: app)
        capture(app, step: "Original grid page and ink before public Duplicate")
        let duplicate = canvas.buttons["Duplicate"].firstMatch
        try requireHittable(duplicate, in: app, step: "Observed public Duplicate action for selected page")
        duplicate.tap()

        try openPages(in: app)
        let copy = app.buttons["pages.open.1"].firstMatch
        try requireHittable(copy, in: app, step: "Pages recognizes the duplicated page")
        XCTAssertTrue(app.buttons["pages.open.0"].exists)
        XCTAssertFalse(app.buttons["pages.open.2"].exists)
        capture(app, step: "Original and duplicate in ordered Pages list")
        copy.tap()
        try assertLayout("Grid", in: app)
        capture(app, step: "Duplicated grid page, inspect retained ink")

        let showSidebar = app.buttons["Show Sidebar"].firstMatch
        if showSidebar.exists && showSidebar.isHittable { showSidebar.tap() }
        let home = app.buttons["Home"].firstMatch
        try requireHittable(home, in: app, step: "Leave the exact synthetic drawing through Home")
        home.tap()
        capture(app, step: "Synthetic drawing left through Home before process restart")
        app.terminate()
        app.launch()
        let reopenSidebar = app.buttons["Show Sidebar"].firstMatch
        if reopenSidebar.exists && reopenSidebar.isHittable { reopenSidebar.tap() }
        let savedDrawing = app.scrollViews.containing(.button, identifier: "Home").staticTexts[drawingName].firstMatch
        try requireHittable(savedDrawing, in: app, step: "Reopen the exact unique synthetic drawing after process restart")
        savedDrawing.tap()
        try selectTool("Selection", in: app)
        try openPages(in: app)
        let reopenedCopy = app.buttons["pages.open.1"].firstMatch
        try requireHittable(reopenedCopy, in: app, step: "Two persisted pages after actual reopen")
        XCTAssertTrue(app.buttons["pages.open.0"].exists)
        XCTAssertFalse(app.buttons["pages.open.2"].exists)
        capture(app, step: "Reopened drawing has exactly two recognized pages")
        reopenedCopy.tap()
        try assertLayout("Grid", in: app)
        capture(app, step: "Reopened duplicated Grid page, inspect retained ink")
        try openPages(in: app)
        let exportPDF = app.buttons["Export pages as PDF"].firstMatch
        try requireHittable(exportPDF, in: app, step: "Normal Pages PDF export action")
        exportPDF.tap()
        capture(app, step: "STOP: actual Pages PDF exporter before choosing a destination")
    }

    func testReopenNamedSyntheticDuplicateAndInspectPDFExporter() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AIChat.isEnabled", "NO", "-DisableCloudSync", "YES",
            "-WhatsNewLastBuild", "999999"
        ]
        launchedApp = app
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        dismissObservedWhatsNew(in: app)
        let showSidebar = app.buttons["Show Sidebar"].firstMatch
        if showSidebar.exists && showSidebar.isHittable { showSidebar.tap() }
        let home = app.buttons["Home"].firstMatch
        try requireHittable(home, in: app, step: "Observed Home button before reopening known synthetic drawing")
        home.tap()
        capture(app, step: "Home before process restart, known synthetic duplicate retained")
        app.terminate()
        app.launch()
        dismissObservedWhatsNew(in: app)
        let reopenSidebar = app.buttons["Show Sidebar"].firstMatch
        if reopenSidebar.exists && reopenSidebar.isHittable { reopenSidebar.tap() }
        // This exact name was created and captured by the prior public duplicate run.
        let savedDrawing = app.staticTexts["Pages-Duplicate-DDB10D13"].firstMatch
        let recentLists = app.scrollViews.containing(.staticText, identifier: "Pages-Duplicate-DDB10D13")
            .allElementsBoundByIndex
        if let recentList = recentLists.min(by: { $0.frame.height < $1.frame.height }) {
            for _ in 0..<6 where !savedDrawing.isHittable {
                recentList.swipeLeft(velocity: .slow)
            }
        }
        try requireHittable(savedDrawing, in: app, step: "Exact synthetic drawing in observed Home recent list")
        savedDrawing.tap()
        try selectTool("Selection", in: app)
        try openPages(in: app)
        let copy = app.buttons["pages.open.1"].firstMatch
        try requireHittable(copy, in: app, step: "Persisted duplicate after Home and process restart")
        XCTAssertTrue(app.buttons["pages.open.0"].exists)
        XCTAssertFalse(app.buttons["pages.open.2"].exists)
        capture(app, step: "Persisted original and copy in Pages after restart")
        copy.tap()
        // Opening a list row moves the camera. The observed second header is the copy.
        let headers = app.webViews.firstMatch.staticTexts.matching(identifier: "Page 1")
        XCTAssertEqual(headers.count, 2)
        let copiedHeader = headers.element(boundBy: 1)
        try requireHittable(copiedHeader, in: app, step: "Observed copied Page 1 header after reopen")
        copiedHeader.tap()
        try assertLayout("Grid", in: app)
        capture(app, step: "Persisted duplicated Grid page and ink after restart")
        try openPages(in: app)
        let exportPDF = app.buttons["Export pages as PDF"].firstMatch
        let pagesList = app.collectionViews.containing(.button, identifier: "Export pages as PDF").firstMatch
        if pagesList.exists {
            for _ in 0..<3 where !exportPDF.isHittable { pagesList.swipeUp(velocity: .slow) }
        }
        try requireHittable(exportPDF, in: app, step: "Normal PDF export for reopened synthetic duplicate")
        exportPDF.tap()
        capture(app, step: "STOP: Pages PDF export requested, inspect destination separately")
    }

    private func dismissObservedWhatsNew(in app: XCUIApplication) {
        let whatsNew = app.navigationBars.matching(
            NSPredicate(format: "identifier IN %@", ["What's New", "What’s New in ExcalidrawZ"])
        ).firstMatch
        if whatsNew.waitForExistence(timeout: 5) {
            let close = whatsNew.buttons["Close"].firstMatch
            XCTAssertTrue(close.isHittable)
            close.tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: whatsNew
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
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
        let menu = app.buttons["toolbar.moreTools"].firstMatch
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
