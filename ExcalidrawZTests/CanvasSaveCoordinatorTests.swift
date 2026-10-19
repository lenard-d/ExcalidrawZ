import Foundation
import XCTest
@testable import ExcalidrawZ

final class CanvasSaveCoordinatorTests: XCTestCase {
    private func fixture(_ initial: String = "original") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Drawing.excalidraw")
        try Data(initial.utf8).write(to: url)
        return url
    }

    private func register(_ files: ExternalFileSaveCoordinator, _ url: URL, _ owner: CanvasMutationSession) async throws {
        let accepted = await files.recordRead(try ExternalFileVersion(content: Data(contentsOf: url), at: url), at: url, session: owner.saveSession)
        XCTAssertTrue(accepted)
    }

    private func owner(generation: UInt64 = 1) -> CanvasMutationSession {
        CanvasMutationSession(fileID: "drawing", saveSession: UUID(), loadGeneration: generation)
    }

    func testPausedOlderCaptureCannotReplaceNewerDurableSceneOrClearDirtyState() async throws {
        let url = try fixture()
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let owner = owner()
        try await register(files, url, owner)
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler {}
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: owner.fileID, revision: 1)
        let oldState = try XCTUnwrap(scheduler.takeFlushState())
        let oldCapture = captures.capture(owner: owner)
        let gate = SaveCaptureGate()
        let old = Task {
            try await gate.pause()
            try await files.save(Data("revision 1".utf8), to: url, session: owner.saveSession, capture: oldCapture, writer: ExternalFileWriter.write)
            return oldCapture.acknowledgeDurable {
                scheduler.markCommitted(snapshotRevision: 1, fallbackRevision: oldState.expectedRevision)
            }
        }
        await gate.waitUntilPaused()
        scheduler.recordPendingContentDirty(fileID: owner.fileID, revision: 2)
        let latest = captures.capture(owner: owner)
        try await files.save(Data("revision 2".utf8), to: url, session: owner.saveSession, capture: latest, writer: ExternalFileWriter.write)
        XCTAssertTrue(latest.acknowledgeDurable { scheduler.markCommitted(snapshotRevision: 2, fallbackRevision: 2) })
        await gate.release()
        do { _ = try await old.value; XCTFail("The delayed old capture must be rejected") }
        catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: url), "revision 2")
        XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
        XCTAssertFalse(captures.hasPendingSave)
        let pending = await files.pendingContent(at: url, session: owner.saveSession)
        XCTAssertNil(pending)
    }

    func testFailedLatestSaveRetainsExactBytesAndRetryAcknowledgesOnlyLatest() async throws {
        let url = try fixture()
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let owner = owner()
        try await register(files, url, owner)
        let old = captures.capture(owner: owner)
        let latest = captures.capture(owner: owner)
        let bytes = Data("latest complete scene".utf8)
        do {
            try await files.save(bytes, to: url, session: owner.saveSession, capture: latest) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("The writer must fail")
        } catch is ExternalFileSaveFailure { }
        XCTAssertTrue(captures.hasPendingSave)
        XCTAssertFalse(latest.acknowledgeDurable { XCTFail("A failed write is not durable") })
        XCTAssertEqual(try String(contentsOf: url), "original")
        let pending = await files.pendingContent(at: url, session: owner.saveSession)
        XCTAssertEqual(pending, bytes)
        do {
            try await files.save(Data("older".utf8), to: url, session: owner.saveSession, capture: old, writer: ExternalFileWriter.write)
            XCTFail("Old bytes must not replace the failed latest request")
        } catch is CancellationError { }
        try await files.retry(at: url, session: owner.saveSession, writer: ExternalFileWriter.write)
        XCTAssertTrue(latest.acknowledgeDurable {})
        XCTAssertFalse(old.acknowledgeDurable {})
        XCTAssertFalse(captures.hasPendingSave)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testCancelledQueuedLatestSaveRemainsRetryableAfterOlderInFlightWriterFinishes() async throws {
        let url = try fixture()
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let owner = owner()
        try await register(files, url, owner)
        let first = captures.capture(owner: owner)
        let writer = SaveCaptureGate()
        let old = Task {
            try await files.save(Data("first".utf8), to: url, session: owner.saveSession, capture: first) { content, target, baseline in
                try await writer.pause()
                return try await ExternalFileWriter.write(content, to: target, replacing: baseline)
            }
        }
        await writer.waitUntilPaused()
        let latest = captures.capture(owner: owner)
        let bytes = Data("latest".utf8)
        let queued = Task { try await files.save(bytes, to: url, session: owner.saveSession, capture: latest, writer: ExternalFileWriter.write) }
        // Observe actual admission to the production writer, not just task creation.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await files.pendingContent(at: url, session: owner.saveSession) != bytes {
            guard ContinuousClock.now < deadline else { XCTFail("Latest request did not enter the queue"); throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(1))
        }
        queued.cancel()
        await writer.release()
        try await old.value
        do { try await queued.value; XCTFail("The queued write must report cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: url), "first")
        XCTAssertFalse(first.acknowledgeDurable {})
        XCTAssertTrue(captures.hasPendingSave)
        let pending = await files.pendingContent(at: url, session: owner.saveSession)
        XCTAssertEqual(pending, bytes)
        try await files.retry(at: url, session: owner.saveSession, writer: ExternalFileWriter.write)
        XCTAssertTrue(latest.acknowledgeDurable {})
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testCancellationDuringRealInFlightOutcomeDoesNotTurnSuccessfulWriteIntoFailure() async throws {
        let url = try fixture()
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let owner = owner()
        try await register(files, url, owner)
        let capture = captures.capture(owner: owner)
        let gate = InFlightReceiptGate()
        let save = Task {
            try await files.save(Data("confirmed despite waiter cancellation".utf8), to: url, session: owner.saveSession, capture: capture) { content, target, baseline in
                await gate.pause()
                // The already-started provider callback owns its outcome, independently of the waiter.
                return try await Task.detached { try await ExternalFileWriter.write(content, to: target, replacing: baseline) }.value
            }
        }
        await gate.waitUntilPaused()
        save.cancel()
        await gate.release()
        try await save.value
        XCTAssertEqual(try String(contentsOf: url), "confirmed despite waiter cancellation")
        XCTAssertTrue(capture.acknowledgeDurable {})
        XCTAssertFalse(captures.hasPendingSave)
        let pending = await files.pendingContent(at: url, session: owner.saveSession)
        XCTAssertNil(pending)
    }

    @MainActor
    func testOwnedOperationCompletesBeforeFreshSnapshotAndActualDurableAcknowledgement() async throws {
        let url = try fixture()
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let mutations = OwnedCanvasMutationCoordinator()
        let owner = owner()
        try await register(files, url, owner)
        let beforeOperation = captures.capture(owner: owner)
        // This synchronous intent invalidates captures made before dispatching owned JS work.
        _ = captures.capture(owner: owner)
        let gate = InFlightReceiptGate()
        var scene = "before operation"
        let operation = Task { @MainActor in
            try await mutations.perform(in: owner) {
                await gate.pause()
                scene = "completed operation"
            }
        }
        await gate.waitUntilPaused()
        let flushed = XCTestExpectation(description: "Owned scene durably saved")
        let flush = Task { @MainActor in
            guard await mutations.waitUntilIdle() else { throw CancellationError() }
            let revision = try XCTUnwrap(mutations.pendingRevision(for: owner))
            let fresh = captures.capture(owner: owner)
            try await files.save(Data(scene.utf8), to: url, session: owner.saveSession, capture: fresh, writer: ExternalFileWriter.write)
            fresh.acknowledgeDurable { mutations.acknowledge(revision) }
            flushed.fulfill()
        }
        XCTAssertTrue(mutations.hasPendingSave)
        XCTAssertFalse(beforeOperation.acknowledgeDurable {})
        await gate.release()
        try await operation.value
        try await flush.value
        let result = await XCTWaiter.fulfillment(of: [flushed], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(try String(contentsOf: url), "completed operation")
        XCTAssertFalse(mutations.hasPendingSave)
        XCTAssertFalse(captures.hasPendingSave)
    }

    func testSameFileNewLoadGenerationRejectsPausedOldCapture() async throws {
        let url = try fixture()
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let original = owner()
        try await register(files, url, original)
        let old = captures.capture(owner: original)
        captures.invalidate()
        let reloaded = CanvasMutationSession(fileID: original.fileID, saveSession: original.saveSession, loadGeneration: 2)
        let latest = captures.capture(owner: reloaded)
        try await files.save(Data("new generation".utf8), to: url, session: reloaded.saveSession, capture: latest, writer: ExternalFileWriter.write)
        do {
            try await files.save(Data("old generation".utf8), to: url, session: original.saveSession, capture: old, writer: ExternalFileWriter.write)
            XCTFail("Same file ID does not make an old load current")
        } catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: url), "new generation")
        XCTAssertTrue(latest.acknowledgeDurable {})
        XCTAssertFalse(old.acknowledgeDurable {})
    }

    func testCaptureCannotWriteAnotherSessionOrTarget() async throws {
        let firstURL = try fixture()
        let secondURL = try fixture("second target")
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let firstOwner = owner()
        let secondOwner = owner()
        try await register(files, firstURL, firstOwner)
        try await register(files, secondURL, secondOwner)
        let capture = captures.capture(owner: firstOwner)
        do {
            try await files.save(Data("wrong target".utf8), to: secondURL, session: secondOwner.saveSession, capture: capture, writer: ExternalFileWriter.write)
            XCTFail("A capture belongs to its exact save session")
        } catch is CancellationError { }
        XCTAssertEqual(try String(contentsOf: firstURL), "original")
        XCTAssertEqual(try String(contentsOf: secondURL), "second target")
        let pending = await files.pendingContent(at: secondURL, session: secondOwner.saveSession)
        XCTAssertNil(pending)
        XCTAssertTrue(captures.hasPendingSave)
    }

    func testOlderMetadataIsRejectedAndFreshMetadataMergesIntoNewestScene() async throws {
        let url = try fixture("{\"elements\":[\"original\"],\"appState\":{\"gridSize\":10}}")
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let owner = owner()
        try await register(files, url, owner)
        let oldMetadata = captures.capture(owner: owner)
        let full = captures.capture(owner: owner)
        let scene = Data("{\"elements\":[\"latest\"],\"appState\":{\"gridSize\":20}}".utf8)
        try await files.save(scene, to: url, session: owner.saveSession, capture: full, writer: ExternalFileWriter.write)
        do {
            try await files.saveAppState(from: Data("{\"appState\":{\"gridSize\":5}}".utf8), to: url, session: owner.saveSession, capture: oldMetadata, writer: ExternalFileWriter.write)
            XCTFail("Old app state must not replace a newer full scene")
        } catch is CancellationError { }
        let freshMetadata = captures.capture(owner: owner)
        try await files.saveAppState(from: Data("{\"appState\":{\"gridSize\":30}}".utf8), to: url, session: owner.saveSession, capture: freshMetadata, writer: ExternalFileWriter.write)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(document["elements"] as? [String], ["latest"])
        XCTAssertEqual((document["appState"] as? [String: Any])?["gridSize"] as? Int, 30)
        XCTAssertTrue(freshMetadata.acknowledgeDurable {})
        XCTAssertFalse(full.acknowledgeDurable {})
    }

    func testExternalConflictCannotAcknowledgeOrOverwriteEitherVersionOnRetry() async throws {
        let url = try fixture()
        let files = ExternalFileSaveCoordinator()
        let captures = CanvasSaveCoordinator()
        let owner = owner()
        try await register(files, url, owner)
        let capture = captures.capture(owner: owner)
        let local = Data("local edits".utf8)
        try Data("external edits".utf8).write(to: url, options: .atomic)
        for retry in [false, true] {
            do {
                if retry { try await files.retry(at: url, session: owner.saveSession, writer: ExternalFileWriter.write) }
                else { try await files.save(local, to: url, session: owner.saveSession, capture: capture, writer: ExternalFileWriter.write) }
                XCTFail("A conflict requires an explicit recovery choice")
            } catch let failure as ExternalFileSaveFailure { XCTAssertTrue(failure.cause is ExternalFileConflict) }
        }
        XCTAssertEqual(try String(contentsOf: url), "external edits")
        let pending = await files.pendingContent(at: url, session: owner.saveSession)
        XCTAssertEqual(pending, local)
        XCTAssertTrue(captures.hasPendingSave)
        XCTAssertFalse(capture.acknowledgeDurable {})
    }

    @MainActor
    func testRecoveryExportWaitsForOperationThenReadsFreshSceneWithoutSaving() async throws {
        let captures = CanvasSaveCoordinator()
        _ = captures.capture(owner: owner())
        var scene = "cached old scene"
        let snapshot = try await CanvasRecoverySnapshot.capture(owner: 1, currentOwner: { 1 }, waitUntilIdle: {
            scene = "completed live operation"
            return true
        }, read: { scene })
        XCTAssertEqual(snapshot, "completed live operation")
        XCTAssertTrue(captures.hasPendingSave)
    }

    @MainActor
    func testRecoveryExportPropagatesReadFailureWithoutCachedFallback() async throws {
        do {
            let _: String = try await CanvasRecoverySnapshot.capture(owner: 1, currentOwner: { 1 }, waitUntilIdle: { true }, read: { throw CocoaError(.fileReadUnknown) })
            XCTFail("A failed live read must not export cached bytes")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadUnknown) }
    }

    @MainActor
    func testRecoveryExportRejectsSameFileReloadOrEditDuringRead() async throws {
        let original = ExternalSaveTerminationToken(fileID: "drawing", session: UUID(), editRevision: 1, loadGeneration: 1)
        var current = original
        do {
            let _: String = try await CanvasRecoverySnapshot.capture(owner: original, currentOwner: { current }, waitUntilIdle: { true }, read: {
                current = ExternalSaveTerminationToken(fileID: original.fileID, session: original.session, editRevision: 1, loadGeneration: 2)
                return "stale scene"
            })
            XCTFail("A changed owner cannot export the previous scene")
        } catch is CancellationError { }
    }
}

private actor SaveCaptureGate {
    private nonisolated let entered = XCTestExpectation(description: "Capture or writer paused")
    private var released = false

    func pause() async throws {
        entered.fulfill()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    nonisolated func waitUntilPaused() async {
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func release() { released = true }
}

private actor InFlightReceiptGate {
    private nonisolated let entered = XCTestExpectation(description: "In-flight operation entered")
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
