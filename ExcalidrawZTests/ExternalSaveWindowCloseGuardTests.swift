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
    func testFailedSaveKeepsWindowAliveAndRetryCanClose() async throws {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        var closes = 0
        window.onFlush = { false }
        try await boundedSaveTestValue(decision.requestClose(participant: window, originalShouldClose: { XCTFail("Failed saves must not reach original delegate"); return true }, close: { closes += 1 }))
        XCTAssertEqual(closes, 0)
        window.onFlush = { window.hasPendingExternalSnapshot = false; return true }
        try await boundedSaveTestValue(decision.requestClose(participant: window, originalShouldClose: { true }, close: { closes += 1 }))
        XCTAssertEqual(closes, 1)
    }

    @MainActor
    func testRepeatedCloseWaitsOnceAndClosesOnlyItsWindow() async throws {
        let first = Window()
        let second = Window()
        let firstDecision = ExternalSaveWindowCloseDecision()
        let secondDecision = ExternalSaveWindowCloseDecision()
        let gate = SaveTestGate()
        first.onFlush = {
            do { try await gate.pause() } catch { return false }
            first.hasPendingExternalSnapshot = false
            return true
        }
        second.onFlush = { false }
        var firstCloses = 0
        var secondCloses = 0
        let initial = firstDecision.requestClose(participant: first, originalShouldClose: { true }, close: { firstCloses += 1 })
        try await gate.waitUntilPaused()
        let repeated = firstDecision.requestClose(participant: first, originalShouldClose: { true }, close: { XCTFail("The duplicate must use the original request") })
        try await boundedSaveTestValue(secondDecision.requestClose(participant: second, originalShouldClose: { true }, close: { secondCloses += 1 }))
        XCTAssertEqual(first.flushCount, 1)
        XCTAssertEqual(secondCloses, 0)
        await gate.release()
        try await boundedSaveTestValue(initial)
        try await boundedSaveTestValue(repeated)
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 0)
    }

    @MainActor
    func testNewEditDuringFlushVetoesCloseEvenIfFlushReturnsSuccess() async throws {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        window.onFlush = { window.revision += 1; window.hasPendingExternalSnapshot = false; return true }
        try await boundedSaveTestValue(decision.requestClose(participant: window, originalShouldClose: { XCTFail("Changed edit token must veto first"); return true }, close: { XCTFail("A new edit must retain the editor") }))
    }

    @MainActor
    func testOriginalDelegateCanVetoAfterSuccessfulFlush() async throws {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        window.onFlush = { window.hasPendingExternalSnapshot = false; return true }
        var originalCalls = 0
        try await boundedSaveTestValue(decision.requestClose(participant: window, originalShouldClose: { originalCalls += 1; return false }, close: { XCTFail("The original delegate veto must be preserved") }))
        XCTAssertEqual(originalCalls, 1)
    }

    @MainActor
    func testOriginalDelegateCannotIntroduceUnsavedEditThenClose() async throws {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        window.onFlush = { window.hasPendingExternalSnapshot = false; return true }
        try await boundedSaveTestValue(decision.requestClose(participant: window, originalShouldClose: {
            window.revision += 1
            window.hasPendingExternalSnapshot = true
            return true
        }, close: { XCTFail("The final close must still validate edits made by the original delegate") }))
    }

    @MainActor
    func testCancellationDoesNotCloseAfterInFlightFlushFinishes() async throws {
        let decision = ExternalSaveWindowCloseDecision()
        let window = Window()
        let gate = SaveTestGate()
        window.onFlush = {
            do { try await gate.pause() } catch { return false }
            window.hasPendingExternalSnapshot = false
            return true
        }
        let request = decision.requestClose(participant: window, originalShouldClose: { true }, close: { XCTFail("A cancelled or detached request must not close") })
        try await gate.waitUntilPaused()
        decision.cancel()
        await gate.release()
        try await boundedSaveTestValue(request)
    }
}
