import XCTest
@testable import ExcalidrawZ

final class PageModeControllerTests: XCTestCase {
    @MainActor
    func testSecondActionCannotOverlapPendingSceneCommand() async throws {
        let entered = expectation(description: "Scene command entered")
        var resume: CheckedContinuation<String, Error>?
        var calls = 0
        let controller = PageModeController(execute: { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                resume = continuation
                entered.fulfill()
            }
        }, render: { _, _ in Data() }, isCurrent: { true })
        let first = Task { await controller.perform(.init(action: .list)) }
        await fulfillment(of: [entered], timeout: 1)
        let second = await controller.perform(.init(action: .add, width: 595, height: 842))
        resume?.resume(returning: #"{"pages":[],"openedPageID":null}"#)
        let succeeded = await first.value
        XCTAssertFalse(second)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testDocumentSwitchDuringExecutionDiscardsResultAndPrivateExport() async {
        var current = true
        let controller = PageModeController(execute: { _ in
            current = false
            return #"{"pages":[{"id":"old","title":"Private","width":595,"height":842,"locked":false}],"openedPageID":null}"#
        }, render: { _, _ in Data() }, isCurrent: { current })
        controller.exportData = Data("old private PDF".utf8)
        let success = await controller.perform(.init(action: .list))
        XCTAssertFalse(success)
        XCTAssertFalse(controller.isValid)
        XCTAssertTrue(controller.pages.isEmpty)
        XCTAssertNil(controller.exportData)
    }

    @MainActor
    func testMutationFailureIsVisibleAndDoesNotReplacePageList() async {
        var shouldFail = false
        let controller = PageModeController(execute: { _ in
            if shouldFail { throw PageModeError.unavailable }
            return #"{"pages":[{"id":"kept","title":"Notes","width":595,"height":842,"locked":false}],"openedPageID":null}"#
        }, render: { _, _ in Data() }, isCurrent: { true })
        await controller.perform(.init(action: .list))
        shouldFail = true
        await controller.perform(.init(action: .remove, pageID: "kept"))
        XCTAssertEqual(controller.pages.map(\.id), ["kept"])
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testExportRenderFailurePublishesNoPartialPDF() async {
        var renders = 0
        let controller = PageModeController(execute: { _ in
            #"{"pages":[{"id":"one","title":"One","width":595,"height":842,"locked":false},{"id":"two","title":"Two","width":595,"height":842,"locked":false}],"scene":{"elements":[{"id":"one","type":"frame"},{"id":"two","type":"frame"}],"files":{},"appState":{}}}"#
        }, render: { _, _ in
            renders += 1
            if renders == 2 { throw PageModeError.invalidExport }
            return try PageModePDFTests.image()
        }, isCurrent: { true })
        await controller.exportPDF()
        XCTAssertEqual(renders, 2)
        XCTAssertNil(controller.exportData)
        XCTAssertNotNil(controller.errorMessage)
    }
}
