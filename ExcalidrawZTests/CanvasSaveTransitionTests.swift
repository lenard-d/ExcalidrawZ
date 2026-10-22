import Foundation
import XCTest
@testable import ExcalidrawZ

final class CanvasSaveTransitionTests: XCTestCase {
    @MainActor
    func testOutgoingSaveFinishesBeforeOwnerInvalidationForBothCaptureOrders() async throws {
        for captureBeforeWait in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let first = root.appendingPathComponent("A.excalidraw")
            let second = root.appendingPathComponent("B.excalidraw")
            try Data("old A".utf8).write(to: first)
            try Data("unchanged B".utf8).write(to: second)
            let captures = CanvasSaveCoordinator()
            let files = ExternalFileSaveCoordinator()
            let scheduler = ExcalidrawDocumentContentSnapshotScheduler { _ in }
            defer { scheduler.reset() }
            let outgoing = CanvasMutationSession(fileID: "library A", saveSession: UUID(), loadGeneration: 1)
            var active = outgoing
            let incoming = CanvasMutationSession(fileID: "library B", saveSession: UUID(), loadGeneration: 2)
            let accepted = await files.recordRead(try ExternalFileVersion(content: Data(contentsOf: first), at: first), at: first, session: outgoing.saveSession)
            XCTAssertTrue(accepted)
            scheduler.recordPendingContentDirty(fileID: outgoing.fileID, revision: 1)
            _ = captures.capture(owner: outgoing)
            let gate = SaveTestGate()
            let transition = Task { @MainActor in
                let canLeave = await CanvasSaveTransition.prepare(owner: outgoing, currentOwner: { active }, flush: {
                    let early = captureBeforeWait ? captures.capture(owner: outgoing) : nil
                    do {
                        try await gate.pause()
                        let capture = early ?? captures.capture(owner: outgoing)
                        try await files.save(Data("latest A".utf8), to: first, session: outgoing.saveSession, capture: capture, writer: ExternalFileWriter.write)
                        capture.acknowledgeDurable { scheduler.markCommitted(snapshotRevision: 1, fallbackRevision: 1) }
                    } catch { }
                }, hasPendingSave: { captures.hasPendingSave || scheduler.hasPendingDirtySnapshot() })
                if canLeave { captures.invalidate(); active = incoming }
                return canLeave
            }
            try await gate.waitUntilPaused()
            XCTAssertEqual(active, outgoing, "The production transition module must retain the outgoing owner while capture is delayed")
            XCTAssertTrue(captures.hasPendingSave)
            await gate.release()
            let didLeave = try await boundedSaveTestValue(transition)
            XCTAssertTrue(didLeave)
            XCTAssertEqual(active, incoming)
            XCTAssertEqual(try String(contentsOf: first), "latest A")
            XCTAssertEqual(try String(contentsOf: second), "unchanged B")
            XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
        }
    }

    @MainActor
    func testFailedOrCancelledOutgoingFlushKeepsOwnerAndPendingContent() async throws {
        for cancel in [false, true] {
            let captures = CanvasSaveCoordinator()
            let owner = CanvasMutationSession(fileID: "library", saveSession: UUID(), loadGeneration: 1)
            var active: CanvasMutationSession? = owner
            _ = captures.capture(owner: owner)
            let gate = SaveTestGate()
            let transition = Task { @MainActor in
                let canLeave = await CanvasSaveTransition.prepare(owner: owner, currentOwner: { active }, flush: {
                    // A failed snapshot has no receipt. It must leave full content pending.
                    try? await gate.pause()
                }, hasPendingSave: { captures.hasPendingSave })
                if canLeave { captures.invalidate(); active = nil }
                return canLeave
            }
            try await gate.waitUntilPaused()
            if cancel { transition.cancel() }
            await gate.release()
            let didLeave = try await boundedSaveTestValue(transition)
            XCTAssertFalse(didLeave)
            XCTAssertEqual(active, owner)
            XCTAssertTrue(captures.hasPendingFullContent)
        }
    }

    @MainActor
    func testSameFileGenerationChangeDuringFlushCannotApproveNavigation() async {
        let owner = CanvasMutationSession(fileID: "library", saveSession: UUID(), loadGeneration: 1)
        var active = owner
        let canLeave = await CanvasSaveTransition.prepare(owner: owner, currentOwner: { active }, flush: {
            active = CanvasMutationSession(fileID: owner.fileID, saveSession: owner.saveSession, loadGeneration: 2)
        }, hasPendingSave: { false })
        XCTAssertFalse(canLeave)
    }
}
