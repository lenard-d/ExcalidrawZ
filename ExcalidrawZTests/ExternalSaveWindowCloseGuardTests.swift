import Foundation
import XCTest
@testable import ExcalidrawZ

final class ExternalSaveWindowCloseGuardTests: XCTestCase {
    @MainActor
    private final class Window: ExternalSaveTerminationParticipant {
        let session = UUID()
        var revision: UInt64 = 0
        var hasPendingExternalSnapshot = true
        var flushCount = 0
        var onFlush: () async -> Bool = { true }

        var terminationSaveToken: ExternalSaveTerminationToken {
            ExternalSaveTerminationToken(fileID: "drawing", session: session, editRevision: revision, loadGeneration: 1)
        }

        func flushPendingCanvasSnapshotBeforeTermination() async -> Bool {
            flushCount += 1
            return await onFlush()
        }
    }

    @MainActor
    func testFailedSaveKeepsWindowAliveAndRetryCanClose() async {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        var closes = 0
        window.onFlush = { false }
        await decision.requestClose(participant: window, originalShouldClose: { XCTFail("Failed saves must not reach original delegate"); return true }, close: { closes += 1 }).value
        XCTAssertEqual(closes, 0)
        window.onFlush = { window.hasPendingExternalSnapshot = false; return true }
        await decision.requestClose(participant: window, originalShouldClose: { true }, close: { closes += 1 }).value
        XCTAssertEqual(closes, 1)
    }

    @MainActor
    func testRepeatedCloseWaitsOnceAndClosesOnlyItsWindow() async {
        let first = Window()
        let second = Window()
        let firstDecision = ExternalSaveWindowCloseDecision()
        let secondDecision = ExternalSaveWindowCloseDecision()
        let gate = CloseFlushGate()
        first.onFlush = { await gate.pause(); first.hasPendingExternalSnapshot = false; return true }
        second.onFlush = { false }
        var firstCloses = 0
        var secondCloses = 0
        let initial = firstDecision.requestClose(participant: first, originalShouldClose: { true }, close: { firstCloses += 1 })
        await gate.waitUntilPaused()
        let repeated = firstDecision.requestClose(participant: first, originalShouldClose: { true }, close: { XCTFail("The duplicate must use the original request") })
        await secondDecision.requestClose(participant: second, originalShouldClose: { true }, close: { secondCloses += 1 }).value
        XCTAssertEqual(first.flushCount, 1)
        XCTAssertEqual(secondCloses, 0)
        await gate.release()
        await initial.value
        await repeated.value
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 0)
    }

    @MainActor
    func testNewEditDuringFlushVetoesCloseEvenIfFlushReturnsSuccess() async {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        window.onFlush = { window.revision += 1; window.hasPendingExternalSnapshot = false; return true }
        await decision.requestClose(participant: window, originalShouldClose: { XCTFail("Changed edit token must veto first"); return true }, close: { XCTFail("A new edit must retain the editor") }).value
    }

    @MainActor
    func testOriginalDelegateCanVetoAfterSuccessfulFlush() async {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        window.onFlush = { window.hasPendingExternalSnapshot = false; return true }
        var originalCalls = 0
        await decision.requestClose(participant: window, originalShouldClose: { originalCalls += 1; return false }, close: { XCTFail("The original delegate veto must be preserved") }).value
        XCTAssertEqual(originalCalls, 1)
    }

    @MainActor
    func testOriginalDelegateCannotIntroduceUnsavedEditThenClose() async {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        window.onFlush = { window.hasPendingExternalSnapshot = false; return true }
        await decision.requestClose(participant: window, originalShouldClose: {
            window.revision += 1
            window.hasPendingExternalSnapshot = true
            return true
        }, close: { XCTFail("The final close must still validate edits made by the original delegate") }).value
    }

    @MainActor
    func testCancellationDoesNotCloseAfterInFlightFlushFinishes() async {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        let gate = CloseFlushGate()
        window.onFlush = { await gate.pause(); window.hasPendingExternalSnapshot = false; return true }
        let request = decision.requestClose(participant: window, originalShouldClose: { true }, close: { XCTFail("A cancelled or detached request must not close") })
        await gate.waitUntilPaused()
        decision.cancel()
        await gate.release()
        await request.value
    }
}

private actor CloseFlushGate {
    private nonisolated let entered = XCTestExpectation(description: "Window flush started")
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    nonisolated func waitUntilPaused() async {
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func release() { continuation?.resume(); continuation = nil }
}
