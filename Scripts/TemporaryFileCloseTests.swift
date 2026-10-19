import Foundation
import XCTest
@testable import ExcalidrawZ

final class TemporaryFileCloseTests: XCTestCase {
    let a = URL(fileURLWithPath: "/synthetic/A.excalidraw")
    let b = URL(fileURLWithPath: "/synthetic/B.excalidraw")
    let c = URL(fileURLWithPath: "/synthetic/C.excalidraw")

    @MainActor func testVetoRetainsActiveRowGroupAndConversation() async {
        let state = FileState([a, b], active: .temporaryFile(a))
        _ = await TemporaryFileActions.close([a], fileState: state)
        XCTAssertEqual(state.temporaryFiles, [a, b])
        XCTAssertEqual(state.currentActiveFile, .temporaryFile(a))
        XCTAssertEqual(state.currentActiveGroup, .temporary)
        XCTAssertTrue(state.deletedConversations.isEmpty)
    }

    @MainActor func testCloseAllVetoRetainsEveryRowAndConversation() async {
        let state = FileState([a, b], active: .temporaryFile(a))
        _ = await TemporaryFileActions.close([a, b], fileState: state)
        XCTAssertEqual(state.temporaryFiles, [a, b])
        XCTAssertEqual(state.currentActiveFile, .temporaryFile(a))
        XCTAssertEqual(state.currentActiveGroup, .temporary)
        XCTAssertTrue(state.deletedConversations.isEmpty)
    }

    @MainActor func testAcceptedCloseCommitsOnlyRequestedEffects() async {
        let state = FileState([a, b, c], active: .temporaryFile(a))
        state.transition = { _ in true }
        _ = await TemporaryFileActions.close([a], fileState: state)
        XCTAssertEqual(state.transitionCalls, [.temporaryFile(b)])
        XCTAssertEqual(state.currentActiveFile, .temporaryFile(b))
        XCTAssertEqual(state.temporaryFiles, [b, c])
        XCTAssertEqual(state.deletedConversations, [a])
        XCTAssertEqual(state.currentActiveGroup, .temporary)
    }

    @MainActor func testAcceptedCloseAllClearsOnlyTemporaryWorkspace() async {
        let state = FileState([a, b], active: .temporaryFile(a))
        state.transition = { _ in true }
        _ = await TemporaryFileActions.close([a, b], fileState: state)
        XCTAssertNil(state.currentActiveFile)
        XCTAssertTrue(state.temporaryFiles.isEmpty)
        XCTAssertNil(state.currentActiveGroup)
        XCTAssertEqual(state.deletedConversations, [a, b])
    }

    @MainActor func testInactiveCloseDoesNotSwitchUnrelatedDocumentOrGroup() async {
        let state = FileState([a, b], active: .library("unrelated"))
        state.currentActiveGroup = .other
        _ = await TemporaryFileActions.close([b], fileState: state)
        XCTAssertTrue(state.transitionCalls.isEmpty)
        XCTAssertEqual(state.currentActiveFile, .library("unrelated"))
        XCTAssertEqual(state.currentActiveGroup, .other)
        XCTAssertEqual(state.temporaryFiles, [a])
        XCTAssertEqual(state.deletedConversations, [b])
    }

    @MainActor func testNoSideEffectDuringWaitAndConcurrentNewFileIsRetained() async throws {
        let state = FileState([a], active: .temporaryFile(a))
        let gate = SaveTestGate()
        state.transition = { _ in try? await gate.pause(); return true }
        let close = Task { await TemporaryFileActions.close([self.a], fileState: state) }
        addTeardownBlock { close.cancel(); await gate.release() }
        try await gate.waitUntilPaused()
        XCTAssertEqual(state.temporaryFiles, [a])
        XCTAssertTrue(state.deletedConversations.isEmpty)
        state.temporaryFiles.append(c)
        state.currentActiveGroup = .other
        await gate.release()
        _ = try await boundedSaveTestValue(close)
        XCTAssertEqual(state.temporaryFiles, [c])
        XCTAssertEqual(state.currentActiveGroup, .other)
        XCTAssertEqual(state.deletedConversations, [a])
    }

    @MainActor func testCancellationDoesNotCommitCloseEffects() async throws {
        let state = FileState([a], active: .temporaryFile(a))
        let gate = SaveTestGate()
        state.transition = { _ in try? await gate.pause(ignoringCancellation: true); return true }
        let close = Task { await TemporaryFileActions.close([self.a], fileState: state) }
        addTeardownBlock { close.cancel(); await gate.release() }
        try await gate.waitUntilPaused()
        close.cancel()
        await gate.release()
        _ = try await boundedSaveTestValue(close)
        XCTAssertEqual(state.temporaryFiles, [a])
        XCTAssertEqual(state.currentActiveGroup, .temporary)
        XCTAssertTrue(state.deletedConversations.isEmpty)
    }

    @MainActor func testRepeatedCloseDoesNotDeleteAgainOrMoveSelection() async {
        let state = FileState([a, b], active: .temporaryFile(a))
        state.transition = { _ in true }
        _ = await TemporaryFileActions.close([a], fileState: state)
        state.deletedConversations = []
        _ = await TemporaryFileActions.close([a], fileState: state)
        XCTAssertEqual(state.currentActiveFile, .temporaryFile(b))
        XCTAssertEqual(state.temporaryFiles, [b])
        XCTAssertEqual(state.transitionCalls.count, 1)
        XCTAssertTrue(state.deletedConversations.isEmpty)
    }

    @MainActor func testVetoAfterWaitPreservesConcurrentRowsAndGroup() async throws {
        let state = FileState([a, b], active: .temporaryFile(a))
        let gate = SaveTestGate()
        state.transition = { _ in try? await gate.pause(); return false }
        let close = Task { await TemporaryFileActions.close([self.a, self.b], fileState: state) }
        addTeardownBlock { close.cancel(); await gate.release() }
        try await gate.waitUntilPaused()
        state.temporaryFiles.append(c)
        state.currentActiveGroup = .other
        await gate.release()
        _ = try await boundedSaveTestValue(close)
        XCTAssertEqual(state.currentActiveFile, .temporaryFile(a))
        XCTAssertEqual(state.temporaryFiles, [a, b, c])
        XCTAssertEqual(state.currentActiveGroup, .other)
        XCTAssertTrue(state.deletedConversations.isEmpty)
    }

    @MainActor func testInactiveCloseAllPreservesUnrelatedWorkspace() async {
        let state = FileState([a, b], active: .library("unrelated"))
        state.currentActiveGroup = .other
        _ = await TemporaryFileActions.close([a, b], fileState: state)
        XCTAssertTrue(state.transitionCalls.isEmpty)
        XCTAssertEqual(state.currentActiveFile, .library("unrelated"))
        XCTAssertEqual(state.currentActiveGroup, .other)
        XCTAssertTrue(state.temporaryFiles.isEmpty)
        XCTAssertEqual(state.deletedConversations, [a, b])
    }

    @MainActor func testOverlappingDestinationCloseRunsAfterAcceptedTransition() async throws {
        let state = FileState([a, b], active: .temporaryFile(a))
        let gate = SaveTestGate()
        var transitions = 0
        state.transition = { _ in
            transitions += 1
            if transitions == 1 { try? await gate.pause() }
            return true
        }
        let first = Task { await TemporaryFileActions.close([self.a], fileState: state) }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await gate.waitUntilPaused()
        let secondStarted = XCTestExpectation(description: "Second close started")
        let secondFinished = XCTestExpectation(description: "Second close must wait")
        secondFinished.isInverted = true
        let second = Task {
            secondStarted.fulfill()
            let result = await TemporaryFileActions.close([self.b], fileState: state)
            secondFinished.fulfill()
            return result
        }
        addTeardownBlock { second.cancel(); await gate.release() }
        let didStart = await XCTWaiter.fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertEqual(didStart, .completed)
        let didWait = await XCTWaiter.fulfillment(of: [secondFinished], timeout: 0.05)
        XCTAssertEqual(didWait, .completed)
        XCTAssertEqual(state.temporaryFiles, [a, b])
        XCTAssertTrue(state.deletedConversations.isEmpty)
        await gate.release()
        _ = try await boundedSaveTestValue(first)
        _ = try await boundedSaveTestValue(second)
        XCTAssertNil(state.currentActiveFile)
        XCTAssertTrue(state.temporaryFiles.isEmpty)
        XCTAssertEqual(state.deletedConversations, [a, b])
        XCTAssertEqual(state.transitionCalls, [.temporaryFile(b), nil])
    }

    @MainActor func testCancelledQueuedCloseReturnsBeforeActiveCloseAndHasNoEffects() async throws {
        let state = FileState([a, b], active: .temporaryFile(a))
        let gate = SaveTestGate()
        state.transition = { _ in try? await gate.pause(); return true }
        let first = Task { await TemporaryFileActions.close([self.a], fileState: state) }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await gate.waitUntilPaused()
        let queuedStarted = XCTestExpectation(description: "Queued close started")
        let queued = Task {
            queuedStarted.fulfill()
            return await TemporaryFileActions.close([self.b], fileState: state)
        }
        addTeardownBlock { queued.cancel(); await gate.release() }
        let didStart = await XCTWaiter.fulfillment(of: [queuedStarted], timeout: 1)
        XCTAssertEqual(didStart, .completed)
        queued.cancel()
        let accepted = try await boundedSaveTestValue(queued)
        XCTAssertFalse(accepted)
        XCTAssertEqual(state.temporaryFiles, [a, b])
        XCTAssertTrue(state.deletedConversations.isEmpty)
        await gate.release()
        _ = try await boundedSaveTestValue(first)
        XCTAssertEqual(state.currentActiveFile, .temporaryFile(b))
        XCTAssertEqual(state.temporaryFiles, [b])
        XCTAssertEqual(state.deletedConversations, [a])
        state.transition = { _ in true }
        let following = Task { await TemporaryFileActions.close([self.b], fileState: state) }
        addTeardownBlock { following.cancel() }
        let followingAccepted = try await boundedSaveTestValue(following)
        XCTAssertTrue(followingAccepted)
        XCTAssertNil(state.currentActiveFile)
        XCTAssertTrue(state.temporaryFiles.isEmpty)
        XCTAssertEqual(state.deletedConversations, [a, b])
    }

    @MainActor func testQueuedCloseUsesCurrentStateAfterFirstTransitionVeto() async throws {
        let state = FileState([a, b], active: .temporaryFile(a))
        let gate = SaveTestGate()
        state.transition = { _ in try? await gate.pause(); return false }
        let first = Task { await TemporaryFileActions.close([self.a], fileState: state) }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await gate.waitUntilPaused()
        let secondStarted = XCTestExpectation(description: "Second close started")
        let second = Task {
            secondStarted.fulfill()
            return await TemporaryFileActions.close([self.b], fileState: state)
        }
        addTeardownBlock { second.cancel(); await gate.release() }
        let didStart = await XCTWaiter.fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertEqual(didStart, .completed)
        await gate.release()
        let firstAccepted = try await boundedSaveTestValue(first)
        let secondAccepted = try await boundedSaveTestValue(second)
        XCTAssertFalse(firstAccepted)
        XCTAssertTrue(secondAccepted)
        XCTAssertEqual(state.currentActiveFile, .temporaryFile(a))
        XCTAssertEqual(state.temporaryFiles, [a])
        XCTAssertEqual(state.deletedConversations, [b])
        XCTAssertEqual(state.transitionCalls, [.temporaryFile(b)])
    }

    @MainActor func testDifferentFileStatesDoNotShareAdmission() async throws {
        let firstState = FileState([a], active: .temporaryFile(a))
        let gate = SaveTestGate()
        firstState.transition = { _ in try? await gate.pause(); return false }
        let first = Task { await TemporaryFileActions.close([self.a], fileState: firstState) }
        addTeardownBlock { first.cancel(); await gate.release() }
        try await gate.waitUntilPaused()
        let secondState = FileState([b], active: .temporaryFile(b))
        secondState.transition = { _ in true }
        let second = Task { await TemporaryFileActions.close([self.b], fileState: secondState) }
        addTeardownBlock { second.cancel() }
        _ = try await boundedSaveTestValue(second)
        XCTAssertNil(secondState.currentActiveFile)
        XCTAssertTrue(secondState.temporaryFiles.isEmpty)
        XCTAssertEqual(firstState.currentActiveFile, .temporaryFile(a))
        XCTAssertEqual(firstState.temporaryFiles, [a])
        await gate.release()
        _ = try await boundedSaveTestValue(first)
    }
}
