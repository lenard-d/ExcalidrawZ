import JavaScriptCore
import XCTest
@testable import ExcalidrawZ

final class PageModeSceneTests: XCTestCase {
    private var context: JSContext!

    override func setUp() {
        context = JSContext()
        context.evaluateScript(#"""
        var elements = [], writes = [], focus = null, nextID = 1;
        var files = { image: { id: "image", dataURL: "data:image/png;base64,synthetic" } };
        var appState = { viewBackgroundColor: "#ffffff", viewModeEnabled: false };
        var window = { excalidrawZHelper: {
            currentFileId: "drawing",
            _api: {
                getSceneElementsIncludingDeleted: () => elements,
                getAppState: () => appState,
                getFiles: () => files,
            },
            createElements: skeletons => skeletons.map(value => ({ ...value, id: "new" + nextID++, isDeleted: false })),
            addElements: (added, options) => { writes.push({ before: JSON.stringify(elements), options }); elements.push(...added); },
            updateElements: (patches, options) => {
                writes.push({ before: JSON.stringify(elements), options });
                for (const patch of patches) Object.assign(elements.find(value => value.id === patch.id), patch.updates);
            },
            zoomToFitElements: ids => { focus = ids; },
            zoomToFit: () => { focus = "canvas"; },
        } };
        function element(id, extra = {}) {
            return { id, type: "rectangle", x: 0, y: 0, width: 100, height: 80, isDeleted: false, ...extra };
        }
        function page(id, order, extra = {}) {
            return element(id, { type: "frame", name: id, customData: { other: "kept", excalidrawZPage: { version: 1, order } }, ...extra });
        }
        """#)
    }

    func testAddKeepsExistingElementsAndPlacesBlankPageBelowRotatedContent() throws {
        context.evaluateScript("elements = [element('notes', { x: 20, y: 40, width: 400, height: 200, angle: 1, fileId: 'image' })]; var before = JSON.stringify(elements[0]);")
        let result = try run(.init(action: .add, title: "Exercise", width: 595, height: 842))
        XCTAssertEqual(result.pages.map(\.title), ["Exercise"])
        XCTAssertTrue(bool("JSON.stringify(elements[0]) === before && elements[1].y > 40 + 100 + Math.hypot(400, 200)/2 && !elements[0].frameId"))
        XCTAssertTrue(bool("writes.length === 1 && writes[0].options.captureUpdate === 'IMMEDIATELY'"))
    }

    func testReorderChangesOnlyMetadataAndSurvivesJSONReload() throws {
        context.evaluateScript("elements = [page('first', 0), element('ink', { frameId: 'first' }), page('second', 1)]; var before = elements.map(value => [value.id, value.x, value.y, value.frameId]);")
        _ = try run(.init(action: .move, pageID: "second", offset: -1))
        context.evaluateScript("elements = JSON.parse(JSON.stringify(elements));")
        let reloaded = try run(.init(action: .list))
        XCTAssertEqual(reloaded.pages.map(\.id), ["second", "first"])
        XCTAssertTrue(bool("JSON.stringify(elements.map(value => [value.id, value.x, value.y, value.frameId])) === JSON.stringify(before) && elements[0].customData.other === 'kept' && writes.length === 1"))
    }

    func testRemoveKeepsLiveAndDeletedChildrenAndCanRestoreOneCapture() throws {
        context.evaluateScript("elements = [page('page', 0), element('ink', { frameId: 'page', text: 'answer' }), element('deleted', { frameId: 'page', isDeleted: true }), element('loose')]; var before = JSON.stringify(elements);")
        _ = try run(.init(action: .remove, pageID: "page"))
        XCTAssertTrue(bool("elements[0].isDeleted && elements[1].frameId === null && elements[1].text === 'answer' && !elements[1].isDeleted && elements[2].isDeleted && elements[2].frameId === null && elements.length === 4 && writes.length === 1"))
        context.evaluateScript("elements = JSON.parse(writes[0].before);")
        XCTAssertTrue(bool("JSON.stringify(elements) === before"))
    }

    func testOrdinaryAndDeletedFramesAreNotPages() throws {
        context.evaluateScript("elements = [element('ordinary', { type: 'frame' }), page('deleted', 0, { isDeleted: true }), page('visible', 1)];")
        XCTAssertEqual(try run(.init(action: .list)).pages.map(\.id), ["visible"])
    }

    func testMissingOrderHasStableFallbackAndNewPageStaysLast() throws {
        context.evaluateScript("elements = [page('first', 0), page('second', null)];")
        _ = try run(.init(action: .add, title: "New", width: 595, height: 842))
        XCTAssertEqual(try run(.init(action: .list)).pages.map(\.id), ["first", "second", "new1"])
    }

    func testStaleDocumentAndViewModeCannotWrite() throws {
        context.evaluateScript("window.excalidrawZHelper.currentFileId = 'other';")
        XCTAssertThrowsError(try run(.init(action: .add, width: 595, height: 842)))
        context.evaluateScript("window.excalidrawZHelper.currentFileId = 'drawing'; appState.viewModeEnabled = true;")
        XCTAssertThrowsError(try run(.init(action: .add, width: 595, height: 842)))
        XCTAssertTrue(bool("writes.length === 0"))
    }

    func testLockedPageAndInvalidTitleCannotWrite() throws {
        context.evaluateScript("elements = [page('locked', 0, { locked: true }), page('plain', 1)];")
        XCTAssertThrowsError(try run(.init(action: .remove, pageID: "locked")))
        XCTAssertThrowsError(try run(.init(action: .rename, pageID: "plain", title: "   ")))
        XCTAssertThrowsError(try run(.init(action: .move, pageID: "plain", offset: -1)))
        XCTAssertTrue(bool("writes.length === 0"))
    }

    func testNavigationDoesNotWriteAndExportKeepsLooseContentAndMedia() throws {
        context.evaluateScript("elements = [page('page', 0), element('loose', { fileId: 'image' })];")
        _ = try run(.init(action: .open, pageID: "page"))
        XCTAssertTrue(bool("focus[0] === 'page' && writes.length === 0"))
        let json = try execute(.init(action: .exportScene))
        let snapshot = try PageModeExportSnapshot(json: json)
        let scene = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(snapshot.sceneJSON.utf8)) as? [String: Any])
        XCTAssertEqual((scene["elements"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil((scene["files"] as? [String: Any])?["image"])
    }

    private func run(_ command: PageModeCommand) throws -> PageModeState {
        try JSONDecoder().decode(PageModeState.self, from: Data(execute(command).utf8))
    }

    private func execute(_ command: PageModeCommand) throws -> String {
        context.exception = nil
        context.setObject("drawing", forKeyedSubscript: "expectedFileID" as NSString)
        context.setObject(String(decoding: try JSONEncoder().encode(command), as: UTF8.self), forKeyedSubscript: "commandJSON" as NSString)
        let result = context.evaluateScript("(function() {\n" + PageModeSceneScript.body + "\n})()")
        if let error = context.exception { throw NSError(domain: "SceneScript", code: 1, userInfo: [NSLocalizedDescriptionKey: error.toString() ?? "Script error"]) }
        return try XCTUnwrap(result?.toString())
    }

    private func bool(_ script: String) -> Bool { context.evaluateScript(script).toBool() }
}
