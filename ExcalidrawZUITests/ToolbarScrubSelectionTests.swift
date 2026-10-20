import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit

final class ToolbarScrubSelectionTests: XCTestCase {
    private var launchedApp: XCUIApplication?
    private let defaultDirectToolNames = [
        "Selection", "Rectangle", "Diamond", "Ellipse", "Arrow", "Line", "Draw", "Text", "Insert image",
    ]

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

    func testPlainAndOptionShortcutsUseObservedConfiguredHints() throws {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(control.buttons.count, 2)
        let plain = control.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "(1)")).firstMatch
        XCTAssertTrue(plain.exists, "The first configured tool must expose its plain digit hint")
        let plainTitle = plain.label
        let extraTools = app.buttons["toolbar.extraTools"].firstMatch
        XCTAssertTrue(extraTools.isHittable)
        let alternatePredicate = NSPredicate(format: "label ENDSWITH %@", "(⌥1)")
        let alternateDirect = control.buttons.matching(alternatePredicate).firstMatch
        let alternateTitle: String
        if alternateDirect.exists {
            alternateTitle = alternateDirect.label
            captureEditorPhase(app, name: "Configured direct plain and Option shortcut hints")
        } else {
            extraTools.tap()
            let alternateMenuItem = app.buttons.matching(alternatePredicate).firstMatch
            XCTAssertTrue(alternateMenuItem.waitForExistence(timeout: 3),
                          "The overflow must expose configured position eleven with its Option hint")
            alternateTitle = alternateMenuItem.label
            captureEditorPhase(app, name: "Configured overflow Option shortcut hint before keyboard input")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.65)).tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: alternateMenuItem
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
        }
        let canvas = app.webViews.firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let initial = control.buttons.element(boundBy: 1)
        initial.tap()
        assertSelection(initial, control: control)
        canvas.tap()
        assertSelection(initial, control: control)
        captureEditorPhase(app, name: "Canvas contacted after initial tool selection, before public keyboard input")
        canvas.typeKey("1", modifierFlags: [])
        assertSelection(plain, control: control)
        captureEditorPhase(app, name: "Plain 1 selects observed configured hint \(plainTitle)")

        canvas.typeKey("1", modifierFlags: .option)
        if alternateDirect.exists {
            assertSelection(alternateDirect, control: control)
        } else {
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", alternateTitle), object: extraTools
            )
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed,
                           "Option 1 must activate the tool named by the observed overflow hint")
            XCTAssertFalse(control.buttons.allElementsBoundByIndex.contains(where: \.isSelected))
        }
        captureEditorPhase(app, name: "Option 1 selects observed configured hint \(alternateTitle)")
        canvas.typeKey("1", modifierFlags: [])
        assertSelection(plain, control: control)
        XCTAssertEqual(extraTools.value as? String, "")
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

    func testQuickContactCrossesToolsThenLeavesRow() throws {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let cursor = tool(named: "Selection", in: control)
        let diamond = tool(named: "Diamond", in: control)
        XCTAssertTrue(cursor.isHittable)
        XCTAssertTrue(diamond.isHittable)
        let buttons = control.buttons.allElementsBoundByIndex
        let targetIndex = try XCTUnwrap(buttons.firstIndex { $0.label == diamond.label })
        XCTAssertGreaterThan(targetIndex, 0)
        XCTAssertLessThan(targetIndex + 1, buttons.count)
        let canvas = app.webViews.firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))

        for (phase, originIndex) in [targetIndex - 1, targetIndex + 1].enumerated() {
            cursor.tap()
            assertSelection(cursor, control: control)
            let origin = buttons[originIndex]
            XCTAssertTrue(origin.isHittable)
            let start = origin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            // Cross Diamond near the bottom of its live frame, then leave in the same contact.
            let targetY = control.frame.maxY - 2
            let outsideY = control.frame.maxY + 12
            let ratio = (outsideY - origin.frame.midY) / (targetY - origin.frame.midY)
            let outsideX = origin.frame.midX + (diamond.frame.midX - origin.frame.midX) * ratio
            let exitRatio = (control.frame.maxY - origin.frame.midY) / (outsideY - origin.frame.midY)
            let exitX = origin.frame.midX + (outsideX - origin.frame.midX) * exitRatio
            XCTAssertGreaterThan(exitX, diamond.frame.minX + 2)
            XCTAssertLessThan(exitX, diamond.frame.maxX - 2)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(CGPoint(x: outsideX, y: outsideY)))
            let outside = control.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: outsideX - control.frame.minX, dy: outsideY - control.frame.minY
            ))
            capture(app, name: "Cross-exit phase \(phase): before quick contact on \(origin.label)")
            start.press(forDuration: 0.05, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 3)
            let selectedLabels = control.buttons.allElementsBoundByIndex.filter(\.isSelected).map(\.label)
            let state = XCTAttachment(string: "Phase \(phase), native selected segments after release: \(selectedLabels)")
            state.lifetime = .keepAlways
            add(state)
            capture(app, name: "Cross-exit phase \(phase): released outside, inspect native indicator")
            // Capture the actual canvas result even if native segment state is wrong.
            let x = phase == 0 ? 0.25 : 0.55
            drag(in: canvas, from: CGVector(dx: x, dy: 0.35), to: CGVector(dx: x + 0.15, dy: 0.55))
            capture(app, name: "Cross-exit phase \(phase): canvas must contain a Diamond")
            XCTAssertEqual(selectedLabels, [diamond.label])
        }
        cursor.tap()
        assertSelection(cursor, control: control)
        // Root must inspect held video and canvas images separately from native segment state.
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

    func testNativeTopBarAndSecondaryToolActionsMenu() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        let extraTools = app.buttons["toolbar.extraTools"].firstMatch
        // Run this case before Add in root's fresh default-only simulator.
        assertConfiguredDirectTools(defaultDirectToolNames, in: app)
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(extraTools.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["toolbar.style"].exists)
        XCTAssertTrue(app.buttons["toolbar.share"].isHittable)
        XCTAssertTrue(app.buttons["toolbar.undo"].exists)
        XCTAssertFalse(app.buttons["toolbar.toolLock"].exists)
        XCTAssertFalse(app.buttons["toolbar.protectFile"].exists)
        assertNativeActionGeometry(in: app)
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        XCTAssertEqual(menu.frame.midY, control.frame.midY, accuracy: 12)
        XCTAssertGreaterThanOrEqual(extraTools.frame.minX, control.frame.maxX)
        XCTAssertLessThan(extraTools.frame.maxX, app.buttons["toolbar.undo"].firstMatch.frame.minX)
        capture(app, name: "Native top bar before opening secondary actions")

        let cursor = tool(named: "Selection", in: control)
        cursor.tap()
        assertSelection(cursor, control: control)
        XCTAssertFalse(tool(named: "Laser", in: control).exists)
        extraTools.tap()
        XCTAssertTrue(app.buttons["Mermaid to Excalidraw"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Math"].exists)
        XCTAssertTrue(app.buttons["Insert PDF"].exists)
        XCTAssertTrue(app.buttons["toolbar.pages"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["toolbar.penMode"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["toolbar.toolLock"].exists)
        // The preserved simulator order places Laser after the nine visible tools.
        let laser = tool(named: "Laser", in: app)
        XCTAssertTrue(laser.exists, "Configured overflow tools and insert actions must share the extra-tools menu")
        capture(app, name: "Separate extra-tools menu contains overflow and insert actions")
        laser.tap()
        let noVisibleSelection = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                control.buttons.matching(NSPredicate(format: "isSelected == true")).count == 0
            }, object: control
        )
        XCTAssertEqual(XCTWaiter.wait(for: [noVisibleSelection], timeout: 3), .completed)
        XCTAssertTrue(control.exists)
        XCTAssertTrue((extraTools.value as? String)?.hasPrefix("Laser") == true)
        capture(app, name: "Extra-tools button follows the direct tools and reports Laser")
        extraTools.tap()
        waitForSelectedState(true, of: tool(named: "Laser", in: app))
        laser.tap()
        menu.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.penMode"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.toolLock"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.style"].exists)
        XCTAssertTrue(app.buttons["toolbar.drawingSettings"].exists)
        XCTAssertFalse(app.buttons["toolbar.insertPDF"].exists)
        XCTAssertFalse(tool(named: "Laser", in: app).exists)
        capture(app, name: "Settings ellipsis retains Style and modes without overflow tools")
    }

    func testDrawingSettingsRouteCapture() {
        let app = openSyntheticDrawing()
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let drawingSettings = app.buttons["toolbar.drawingSettings"].firstMatch
        revealMenuAction(drawingSettings, in: app)
        guard drawingSettings.isHittable else {
            captureEditorPhase(app, name: "Drawing settings action unavailable")
            XCTFail("The settings menu must expose Drawing settings")
            return
        }
        drawingSettings.tap()
        let addTool = app.buttons["settings.toolbar.addTool"].firstMatch
        let settingsOpened = addTool.waitForExistence(timeout: 5)
        captureEditorPhase(app, name: "Drawing settings route, capture before any configuration change")
        XCTAssertTrue(settingsOpened)

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: addTool
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.segmentedControls["toolbar.toolPicker"].firstMatch.isHittable)
        captureEditorPhase(app, name: "Drawing settings dismissed by the observed outside blank region")
    }

    func testDefaultToolbarAddsFrameAndLaserAndPersistsAfterRelaunch() {
        // This case changes only root's disposable default context. It must fail before Add if defaults differ.
        let app = openSyntheticDrawing()
        assertConfiguredDirectTools(defaultDirectToolNames, in: app)
        captureEditorPhase(app, name: "Untouched default nine before Add")

        addConfiguredDirectTool("frame", name: "Frame", in: app)
        let tenTools = defaultDirectToolNames + ["Frame"]
        assertConfiguredDirectTools(tenTools, in: app)
        selectConfiguredDirectTool("Frame", in: app)
        captureEditorPhase(app, name: "Frame added as the tenth direct tool")

        addConfiguredDirectTool("laser", name: "Laser", in: app)
        let elevenTools = tenTools + ["Laser"]
        assertConfiguredDirectTools(elevenTools, in: app)
        selectConfiguredDirectTool("Laser", in: app)
        selectConfiguredDirectTool("Frame", in: app)
        captureEditorPhase(app, name: "Frame and Laser follow the unchanged default nine")

        app.terminate()
        let relaunched = openSyntheticDrawing()
        assertConfiguredDirectTools(elevenTools, in: relaunched)
        selectConfiguredDirectTool("Frame", in: relaunched)
        selectConfiguredDirectTool("Laser", in: relaunched)
        captureEditorPhase(relaunched, name: "Eleven direct tools persist after process relaunch and a new drawing")
    }

    func testPenModeAndKeepToolActiveRemainIndependent() {
        let app = openSyntheticDrawing()
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let initialPenMode = menuToggleIsOn("toolbar.penMode", in: app)
        let initialToolLock = menuToggleIsOn("toolbar.toolLock", in: app)
        defer {
            setMenuToggle("toolbar.penMode", to: initialPenMode, menu: menu, in: app)
            setMenuToggle("toolbar.toolLock", to: initialToolLock, menu: menu, in: app)
        }
        app.descendants(matching: .any)["toolbar.toolLock"].firstMatch.tap()
        reopenMenuIfNeeded(menu, in: app)
        waitForMenuToggle("toolbar.toolLock", toBe: !initialToolLock, in: app)
        XCTAssertEqual(menuToggleIsOn("toolbar.penMode", in: app), initialPenMode)

        app.descendants(matching: .any)["toolbar.penMode"].firstMatch.tap()
        reopenMenuIfNeeded(menu, in: app)
        waitForMenuToggle("toolbar.penMode", toBe: !initialPenMode, in: app)
        XCTAssertEqual(menuToggleIsOn("toolbar.toolLock", in: app), !initialToolLock)
        capture(app, name: "Pen mode and keep-tool-active show independent states")
    }

    func testZoomAndInspectorAreAvailableFromTheSecondaryMenu() {
        let app = openSyntheticDrawing()
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let zoom = app.buttons["toolbar.zoom"].firstMatch
        revealMenuAction(zoom, in: app)
        zoom.tap()
        let zoom200 = app.buttons["toolbar.zoom.200"].firstMatch
        XCTAssertTrue(zoom200.waitForExistence(timeout: 3))
        zoom200.tap()
        menu.tap()
        XCTAssertTrue(app.buttons["toolbar.zoom"].waitForExistence(timeout: 3))
        revealMenuAction(zoom, in: app)
        let zoomChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "200"),
            object: app.buttons["toolbar.zoom"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [zoomChanged], timeout: 5), .completed)
        let inspector = app.buttons["toolbar.inspector"].firstMatch
        revealMenuAction(inspector, in: app)
        inspector.tap()
        let search = app.descendants(matching: .any)["toolbar.inspector.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        capture(app, name: "Search inspector opened through the native secondary menu")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
    }

    func testExploreCommandFAndSharePresentation() {
        let app = openSyntheticDrawing()
        let share = app.buttons["toolbar.share"].firstMatch
        guard share.waitForExistence(timeout: 15), share.isHittable else {
            captureEditorPhase(app, name: "STOP Share control unavailable")
            XCTFail("The observed native Share control must be available")
            return
        }
        captureEditorPhase(app, name: "Before Command-F with secondary menu closed")
        app.typeKey("f", modifierFlags: .command)
        let searchOpened = app.textFields.firstMatch.waitForExistence(timeout: 5)
        captureEditorPhase(app, name: "After Command-F, inspect Search inspector")
        guard searchOpened else {
            XCTFail("Command-F must open the observed Search text field")
            return
        }
        guard share.isHittable else {
            captureEditorPhase(app, name: "STOP Share unavailable after Command-F")
            XCTFail("Share must remain accessible with Search open")
            return
        }
        share.tap()
        assertShareMenuDismisses(in: app)
        assertStyleRespondsAndRestores(in: app)
    }

    func testExploreFileProtectionPresentation() {
        let app = openSyntheticDrawing()
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        guard menu.waitForExistence(timeout: 15), menu.isHittable else {
            captureEditorPhase(app, name: "STOP secondary menu unavailable for file protection")
            XCTFail("The observed secondary menu must be available")
            return
        }
        menu.tap()
        let protection = app.buttons["toolbar.protectFile"].firstMatch
        let menuContent = app.collectionViews.containing(.button, identifier: "toolbar.zoom").firstMatch
        guard protection.waitForExistence(timeout: 3), menuContent.exists else {
            captureEditorPhase(app, name: "STOP file protection route unavailable")
            XCTFail("The observed protection action and its containing menu must exist")
            return
        }
        for _ in 0..<4 where !protection.isHittable {
            menuContent.swipeUp()
        }
        guard protection.isHittable else {
            captureEditorPhase(app, name: "STOP file protection action cannot be reached")
            XCTFail("The secondary menu must scroll to file protection")
            return
        }
        protection.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Lock File"].exists)
        XCTAssertFalse(app.buttons["Lock File"].firstMatch.isEnabled)
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: cancel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.segmentedControls["toolbar.toolPicker"].isHittable)
        XCTAssertTrue(menu.isHittable)
        assertStyleRespondsAndRestores(in: app)
        captureEditorPhase(app, name: "File protection cancelled, editor response restored")
    }

    func testShareMenuDismissesAndReturnsToEditor() {
        let app = openSyntheticDrawing()
        let share = app.buttons["toolbar.share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 15))
        XCTAssertTrue(share.isHittable)
        captureEditorPhase(app, name: "Settled B1 toolbar before independent Share")
        share.tap()
        assertShareMenuDismisses(in: app)
        assertStyleRespondsAndRestores(in: app)
        captureEditorPhase(app, name: "Share menu dismissed, Style responds and returns to its original state")
    }

    private func assertShareMenuDismisses(in app: XCUIApplication) {
        let image = app.buttons["Image"].firstMatch
        let file = app.buttons["File"].firstMatch
        let pdf = app.buttons["PDF"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertTrue(image.isHittable)
        XCTAssertTrue(file.isHittable)
        XCTAssertTrue(pdf.isHittable)
        captureEditorPhase(app, name: "Share presents the observed Image, File and PDF menu")
        // The observed Share menu occupies only the upper-right corner.
        let window = app.windows.firstMatch
        let outside = CGPoint(x: window.frame.midX, y: window.frame.midY)
        XCTAssertFalse(image.frame.contains(outside) || file.frame.contains(outside) || pdf.frame.contains(outside))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !image.exists && !file.exists && !pdf.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["toolbar.share"].firstMatch.isHittable)
    }

    private func assertStyleRespondsAndRestores(in app: XCUIApplication) {
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        reopenMenuIfNeeded(menu, in: app)
        let originalStyle = menuToggleIsOn("toolbar.style", in: app)
        setMenuToggle("toolbar.style", to: !originalStyle, menu: menu, in: app)
        setMenuToggle("toolbar.style", to: originalStyle, menu: menu, in: app)
        dismissSettingsMenu(in: app)
    }

    func testUndoThenTapOpensRedoMenu() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let initialFrames = assertNativeActionGeometry(in: app)
        let rectangle = tool(named: "Rectangle", in: control)
        XCTAssertTrue(rectangle.isHittable)
        rectangle.tap()
        assertSelection(rectangle, control: control)
        let canvas = app.webViews.firstMatch
        drag(in: canvas, from: CGVector(dx: 0.5, dy: 0.4), to: CGVector(dx: 0.7, dy: 0.6))
        captureEditorPhase(app, name: "Rectangle before Undo, inspect canvas result")
        let undo = app.buttons["toolbar.undo"].firstMatch
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: undo)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        assertNativeActionGeometry(in: app, matching: initialFrames)
        undo.tap()
        captureEditorPhase(app, name: "After Undo, inspect rectangle removal")
        undo.tap()
        let redo = app.buttons["toolbar.redoAction"].firstMatch
        let undoAction = app.buttons["toolbar.undoAction"].firstMatch
        XCTAssertTrue(redo.waitForExistence(timeout: 5), "A tap must open the menu when only Redo is available")
        XCTAssertTrue(redo.isEnabled)
        XCTAssertTrue(undoAction.exists)
        XCTAssertFalse(undoAction.isEnabled)
        assertNativeActionGeometry(in: app, matching: initialFrames)
        captureEditorPhase(app, name: "Redo-only menu opened with one tap")
        redo.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: redo)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        captureEditorPhase(app, name: "After Redo, inspect rectangle restoration")
        undo.press(forDuration: 1)
        XCTAssertTrue(undoAction.waitForExistence(timeout: 5))
        let historyRestored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            undoAction.isEnabled && redo.exists && !redo.isEnabled
        }, object: undoAction)
        XCTAssertEqual(XCTWaiter.wait(for: [historyRestored], timeout: 5), .completed,
                       "Redo must restore Undo availability and exhaust the redo history")
        assertNativeActionGeometry(in: app, matching: initialFrames)
        captureEditorPhase(app, name: "History state after Redo")
    }

    func testStyleHiddenWithoutSelectionStaysHiddenWhenSelectingANewShape() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let initialFrames = assertNativeActionGeometry(in: app)
        let cursor = tool(named: "Selection", in: control)
        cursor.tap()
        assertSelection(cursor, control: control)
        let panel = app.webViews.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Selected shape actions,")
        ).firstMatch
        let duplicate = app.webViews.buttons["Duplicate"].firstMatch
        let delete = app.webViews.buttons["Delete"].firstMatch
        XCTAssertFalse(duplicate.exists)
        XCTAssertFalse(delete.exists)
        XCTAssertFalse(panel.isHittable)
        // A fresh app starts with Style shown. Hide it before any panel exists.
        setStyle(false, in: app)
        assertNativeActionGeometry(in: app, matching: initialFrames)
        captureEditorPhase(app, name: "Style off with Selection and no panel")

        let rectangle = tool(named: "Rectangle", in: control)
        XCTAssertTrue(rectangle.isHittable)
        rectangle.tap()
        assertSelection(rectangle, control: control)
        let canvas = app.webViews.firstMatch
        drag(in: canvas, from: CGVector(dx: 0.5, dy: 0.4), to: CGVector(dx: 0.7, dy: 0.6))
        cursor.tap()
        assertSelection(cursor, control: control)
        // The rectangle is transparent. Select its straight left border.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Hidden Style uses visibility:hidden and need not appear in WebKit's accessibility tree.
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), "Selection must expose its Duplicate action")
        XCTAssertTrue(delete.exists, "Selection must expose its Delete action")
        XCTAssertFalse(panel.isHittable, "Selection must use stored Style state without another Style request")
        let unexpectedlyShown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: panel
        )
        unexpectedlyShown.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedlyShown], timeout: 2), .completed)
        assertNativeActionGeometry(in: app, matching: initialFrames)
        captureEditorPhase(app, name: "New shape selected while Style remains off")

        setStyle(true, in: app)
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed)
        assertNativeActionGeometry(in: app, matching: initialFrames)
        captureEditorPhase(app, name: "One Style press shows the selected shape panel")
        setStyle(false, in: app)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        assertNativeActionGeometry(in: app, matching: initialFrames)
        captureEditorPhase(app, name: "One more Style press hides the selected shape panel")
    }

    func testPenSelectionAutomaticallyShowsExistingStyleSettings() {
        let app = openSyntheticDrawing()
        let control = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let rectangle = tool(named: "Rectangle", in: control)
        rectangle.tap()
        assertSelection(rectangle, control: control)
        setStyle(false, in: app)
        let panel = app.webViews.otherElements.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Selected shape actions,")
        ).firstMatch
        XCTAssertFalse(panel.isHittable)
        let pen = tool(named: "Draw", in: control)
        XCTAssertTrue(pen.isHittable)
        pen.tap()
        assertSelection(pen, control: control)
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: panel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed)
        captureEditorPhase(app, name: "Selecting Draw automatically shows existing pen settings")
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        menu.tap()
        waitForMenuToggle("toolbar.style", toBe: true, in: app)
        dismissSettingsMenu(in: app)
        assertNativeActionGeometry(in: app)
    }

    private func assertConfiguredDirectTools(_ names: [String], in app: XCUIApplication) {
        let picker = app.segmentedControls["toolbar.toolPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        let countMatches = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in picker.buttons.count == names.count }, object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [countMatches], timeout: 5), .completed,
                       "This case requires its exact configured tool count; never reset preserved preferences")
        let window = app.windows.firstMatch.frame
        for (index, name) in names.enumerated() {
            let button = picker.buttons.element(boundBy: index)
            XCTAssertTrue(button.label == name || button.label.hasPrefix("\(name) ("),
                          "Direct slot \(index + 1) must remain \(name), got \(button.label)")
            XCTAssertTrue(button.isHittable, name)
            XCTAssertGreaterThan(button.frame.width, 0, name)
            XCTAssertGreaterThanOrEqual(button.frame.minX, window.minX, name)
            XCTAssertLessThanOrEqual(button.frame.maxX, window.maxX, name)
            if index > 0 {
                XCTAssertGreaterThanOrEqual(button.frame.minX, picker.buttons.element(boundBy: index - 1).frame.maxX)
            }
        }
        let extraTools = app.buttons["toolbar.extraTools"].firstMatch
        XCTAssertTrue(extraTools.isHittable)
        XCTAssertGreaterThanOrEqual(extraTools.frame.minX, picker.frame.maxX)
        XCTAssertLessThan(extraTools.frame.maxX, app.buttons["toolbar.undo"].firstMatch.frame.minX)
        assertNativeActionGeometry(in: app)
    }

    private func addConfiguredDirectTool(_ identifier: String, name: String, in app: XCUIApplication) {
        app.buttons["toolbar.moreTools"].firstMatch.tap()
        let drawingSettings = app.buttons["toolbar.drawingSettings"].firstMatch
        revealMenuAction(drawingSettings, in: app)
        drawingSettings.tap()
        let addTool = app.descendants(matching: .any)["settings.toolbar.addTool"].firstMatch
        XCTAssertTrue(addTool.waitForExistence(timeout: 5))
        let form = app.collectionViews.containing(.any, identifier: "settings.toolbar.addTool").firstMatch
        XCTAssertTrue(form.exists)
        for _ in 0..<4 {
            guard addTool.exists, form.exists else {
                captureEditorPhase(app, name: "STOP Add tool left the visible settings form during scrolling")
                XCTFail("The settings scroll must retain the Add tool target")
                return
            }
            if addTool.isHittable, form.frame.contains(addTool.frame) { break }
            // A full swipe moves this bottom-clipped row above the virtualized form.
            let distance = min(120, max(40, addTool.frame.maxY - form.frame.maxY + 24))
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        guard addTool.isHittable, form.frame.contains(addTool.frame) else {
            captureEditorPhase(app, name: "STOP Add tool is not fully visible in Drawing settings")
            XCTFail("The observed settings form must scroll to Add tool")
            return
        }
        addTool.tap()
        let choice = app.buttons["settings.toolbar.add.\(identifier)"].firstMatch
        captureEditorPhase(app, name: "Add tool menu before choosing \(name)")
        guard choice.waitForExistence(timeout: 3), choice.isHittable else {
            XCTFail("The owned Add tool menu must expose \(name)")
            return
        }
        choice.tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: addTool
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.segmentedControls["toolbar.toolPicker"].firstMatch.isHittable)
    }

    private func selectConfiguredDirectTool(_ name: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["toolbar.toolPicker"].firstMatch
        let button = tool(named: name, in: picker)
        XCTAssertTrue(button.isHittable)
        button.tap()
        assertSelection(button, control: picker)
        XCTAssertTrue((app.buttons["toolbar.extraTools"].firstMatch.value as? String ?? "").isEmpty,
                       "A direct tool must not also be reported as the active overflow tool")
    }

    @discardableResult
    private func assertNativeActionGeometry(
        in app: XCUIApplication,
        matching initialFrames: [String: CGRect]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String: CGRect] {
        let picker = app.segmentedControls["toolbar.toolPicker"].firstMatch
        var frames: [String: CGRect] = [:]
        for identifier in ["toolbar.undo", "toolbar.extraTools", "toolbar.share", "toolbar.moreTools"] {
            let button = app.buttons[identifier].firstMatch
            XCTAssertTrue(button.exists, identifier, file: file, line: line)
            let frame = button.frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, identifier, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, 44, identifier, file: file, line: line)
            XCTAssertEqual(frame.width, 44, accuracy: 0.5, identifier, file: file, line: line)
            XCTAssertEqual(frame.height, 44, accuracy: 0.5, identifier, file: file, line: line)
            XCTAssertEqual(frame.midY, picker.frame.midY, accuracy: 12, identifier, file: file, line: line)
            if let initial = initialFrames?[identifier] {
                XCTAssertEqual(frame.width, initial.width, accuracy: 0.5, identifier, file: file, line: line)
                XCTAssertEqual(frame.height, initial.height, accuracy: 0.5, identifier, file: file, line: line)
            }
            frames[identifier] = frame
        }
        return frames
    }

    private func revealMenuAction(_ action: XCUIElement, in app: XCUIApplication) {
        let menu = app.collectionViews.containing(.button, identifier: "toolbar.zoom").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        for _ in 0..<4 where !action.isHittable {
            menu.swipeUp()
        }
        XCTAssertTrue(action.isHittable, "The secondary menu must scroll to its command")
    }

    private func setStyle(_ shown: Bool, in app: XCUIApplication) {
        let menu = app.buttons["toolbar.moreTools"].firstMatch
        setMenuToggle("toolbar.style", to: shown, menu: menu, in: app)
        dismissSettingsMenu(in: app)
    }

    private func dismissSettingsMenu(in app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["toolbar.style"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func captureEditorPhase(_ app: XCUIApplication, name: String) {
        capture(app, name: name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name), accessibility tree"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func reopenMenuIfNeeded(_ menu: XCUIElement, in app: XCUIApplication) {
        if !app.descendants(matching: .any)["toolbar.penMode"].firstMatch.exists {
            menu.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.penMode"].firstMatch.waitForExistence(timeout: 3))
    }

    private func menuToggleIsOn(_ identifier: String, in app: XCUIApplication) -> Bool {
        let toggle = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        return toggle.isSelected || (toggle.value as? String) == "1"
    }

    private func waitForMenuToggle(_ identifier: String, toBe enabled: Bool, in app: XCUIApplication) {
        let toggle = app.descendants(matching: .any)[identifier].firstMatch
        let state = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (toggle.isSelected || (toggle.value as? String) == "1") == enabled
        }, object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 5), .completed)
    }

    private func setMenuToggle(_ identifier: String, to enabled: Bool, menu: XCUIElement, in app: XCUIApplication) {
        reopenMenuIfNeeded(menu, in: app)
        if menuToggleIsOn(identifier, in: app) != enabled {
            app.descendants(matching: .any)[identifier].firstMatch.tap()
            reopenMenuIfNeeded(menu, in: app)
            waitForMenuToggle(identifier, toBe: enabled, in: app)
        }
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
