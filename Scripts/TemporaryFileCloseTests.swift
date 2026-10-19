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

}
