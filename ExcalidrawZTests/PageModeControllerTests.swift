import Combine
import XCTest
@testable import ExcalidrawZ

final class PageModeControllerTests: XCTestCase {
    @MainActor
    func testIdleSessionChangeClearsRetainedPagesAndExportWithoutAnotherCommand() async {
        let changes = PassthroughSubject<Void, Never>()
        var generation = 1
        let controller = PageModeController(execute: { _ in
            #"{"pages":[{"id":"old","title":"Private","width":595,"height":842,"locked":false}],"openedPageID":null}"#
        }, render: { _, _ in Data() }, isCurrent: { generation == 1 })
        await controller.perform(.init(action: .list))
        controller.exportData = Data("private PDF".utf8)
        controller.observeSessionChanges(changes.eraseToAnyPublisher())
        let invalidated = expectation(description: "Idle page session invalidated")
        let observation = controller.$isValid.dropFirst().filter { !$0 }.sink { _ in invalidated.fulfill() }
        generation = 2
        changes.send(())
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertTrue(controller.pages.isEmpty)
        XCTAssertNil(controller.exportData)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testCoreRemovalBroadcastInvalidatesIdleSession() async {
        let changes = PassthroughSubject<Void, Never>()
        var hasActiveCore = true
        let controller = PageModeController(execute: { _ in #"{"pages":[],"openedPageID":null}"# }, render: { _, _ in Data() }, isCurrent: { hasActiveCore })
        controller.observeSessionChanges(changes.eraseToAnyPublisher())
        let invalidated = expectation(description: "Removed core invalidates session")
        let observation = controller.$isValid.dropFirst().filter { !$0 }.sink { _ in invalidated.fulfill() }
        hasActiveCore = false
        changes.send(())
        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertFalse(controller.isValid)
        withExtendedLifetime(observation) {}
    }

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
    func testDocumentSwitchWhileCommandThrowsClearsRetainedContent() async {
        var current = true
        var shouldFail = false
        let controller = PageModeController(execute: { _ in
            if shouldFail {
                current = false
                throw PageModeError.documentChanged
            }
            return #"{"pages":[{"id":"old","title":"Private","width":595,"height":842,"locked":false}],"openedPageID":null}"#
        }, render: { _, _ in Data() }, isCurrent: { current })
        await controller.perform(.init(action: .list))
        controller.exportData = Data("private".utf8)
        shouldFail = true
        await controller.perform(.init(action: .rename, pageID: "old", title: "New"))
        XCTAssertFalse(controller.isValid)
        XCTAssertTrue(controller.pages.isEmpty)
        XCTAssertNil(controller.exportData)
        XCTAssertNil(controller.errorMessage)
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
