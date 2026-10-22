import Foundation
import XCTest
@testable import ExcalidrawZ

final class ExternalFileReloadTests: XCTestCase {
    private let original = Data(#"{"elements":[{"id":"original"}],"files":{},"appState":{}}"#.utf8)
    private let saved = Data(#"{"elements":[{"id":"saved"}],"files":{},"appState":{}}"#.utf8)
    private let latest = Data(#"{"elements":[{"id":"latest-stroke"}],"files":{},"appState":{}}"#.utf8)

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Synthetic.excalidraw")
        try original.write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> ExternalFileVersion {
        try ExternalFileVersion(content: Data(contentsOf: url), at: url)
    }

    func testConfirmedSaveNotificationDuringNewStrokeDoesNotReload() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        try await coordinator.save(saved, to: url, session: session, writer: ExternalFileWriter.write)
        let replacement = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true)
        XCTAssertNil(replacement)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testDuplicateNotificationPreservesFailedPendingEditsAndRetry() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        do {
            try await coordinator.save(latest, to: url, session: session) { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("The injected write must fail")
        } catch is ExternalFileSaveFailure { }
        let replacement = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true)
        XCTAssertNil(replacement)
        let pending = await coordinator.pendingContent(at: url, session: session)
        XCTAssertEqual(pending, latest)
        try await coordinator.retry(at: url, session: session, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testChangedBytesWithPendingStrokeRejectReloadAndOverwrite() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        try saved.write(to: url)
        do {
            _ = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true)
            XCTFail("A real changed version must not replace a live stroke")
        } catch is ExternalFileConflict { }
        do {
            try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
            XCTFail("The real changed version must not be overwritten")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let pending = await coordinator.pendingContent(at: url, session: session)
        XCTAssertEqual(pending, latest)
    }

    func testSameBytesWithNewIdentityAreNotAnOwnSaveNotification() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        let baseline = try read(url)
        _ = await coordinator.recordRead(baseline, at: url, session: session)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
        try original.write(to: url)
        let replacement = try read(url)
        XCTAssertNotNil(baseline.identity)
        XCTAssertNotEqual(baseline.identity, replacement.identity)
        do {
            _ = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true)
            XCTFail("Equal bytes cannot hide a different file identity")
        } catch is ExternalFileConflict { }
        do {
            try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
            XCTFail("The stale identity must still block the writer")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCleanExternalReplacementRequiresItsOwnAcceptedSession() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let oldSession = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: oldSession)
        try saved.write(to: url)
        let prepared = try await coordinator.prepareReload(at: url, session: oldSession, hasPendingCanvasEdits: false)
        let newSession = try XCTUnwrap(prepared).session
        do {
            try await coordinator.save(latest, to: url, session: oldSession, writer: ExternalFileWriter.write)
            XCTFail("Preparation cannot change the old session baseline")
        } catch is ExternalFileSaveFailure { }
        try await coordinator.save(latest, to: url, session: newSession, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testAnotherSessionCannotClaimThisSessionsConfirmedSave() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let first = UUID()
        let second = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: first)
        _ = await coordinator.recordRead(try read(url), at: url, session: second)
        try await coordinator.save(saved, to: url, session: first, writer: ExternalFileWriter.write)
        do {
            _ = try await coordinator.prepareReload(at: url, session: second, hasPendingCanvasEdits: true)
            XCTFail("A different session must not absorb the first session's saved version")
        } catch is ExternalFileConflict { }
    }

    @MainActor
    func testFileStateDuplicatePreparationDoesNotChangeOwnerOrLiveError() async throws {
        let url = try fixture()
        let state = FileState()
        let session = try await state.recordExternalFileRead(original, at: url)
        state.installExternalSaveSession(session)
        let owner = state.terminationSaveToken
        state.reportExternalSaveFailure(CocoaError(.fileWriteNoPermission), at: url)
        let existingError = state.externalSaveErrorMessage
        let replacement = try await state.prepareExternalFileReload(at: url)
        XCTAssertNil(replacement)
        XCTAssertEqual(state.terminationSaveToken, owner)
        XCTAssertEqual(state.externalSaveErrorMessage, existingError)
        await ExternalFileSaveCoordinator.shared.releaseSession(session)
    }

    @MainActor
    func testDelayedSaveANotificationAfterSaveBReadsConfirmedB() async throws {
        let url = try fixture()
        let state = FileState()
        let session = try await state.recordExternalFileRead(original, at: url)
        state.installExternalSaveSession(session)
        let coordinator = ExternalFileSaveCoordinator.shared
        try await coordinator.save(saved, to: url, session: session, writer: ExternalFileWriter.write)
        let delayedNotification = try read(url)
        try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
        let current = try await ExternalFileVersion.read(at: url)
        XCTAssertEqual(delayedNotification.content, saved)
        XCTAssertEqual(current.content, latest)
        XCTAssertNotEqual(delayedNotification.identity, current.identity)
        let owner = state.terminationSaveToken
        let replacement = try await state.prepareExternalFileReload(at: url)
        XCTAssertNil(replacement)
        XCTAssertEqual(state.terminationSaveToken, owner)
        XCTAssertEqual(try Data(contentsOf: url), latest)
        await coordinator.releaseSession(session)
    }

    @MainActor
    func testDelayedOwnNotificationCannotHideANewerExternalEdit() async throws {
        let url = try fixture()
        let state = FileState()
        let session = try await state.recordExternalFileRead(original, at: url)
        state.installExternalSaveSession(session)
        let coordinator = ExternalFileSaveCoordinator.shared
        try await coordinator.save(saved, to: url, session: session, writer: ExternalFileWriter.write)
        try latest.write(to: url)
        let prepared = try await state.prepareExternalFileReload(at: url)
        let replacement = try XCTUnwrap(prepared)
        XCTAssertEqual(replacement.content, latest)
        XCTAssertNotEqual(replacement.session, session)
        do {
            try await coordinator.save(original, to: url, session: session, writer: ExternalFileWriter.write)
            XCTFail("A delayed notification cannot advance the original writer baseline")
        } catch let failure as ExternalFileSaveFailure {
            XCTAssertTrue(failure.cause is ExternalFileConflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), latest)
        await coordinator.releaseSession(replacement.session)
        await coordinator.releaseSession(session)
    }

    @MainActor
    func testStaleSuccessfulPreparationReleasesReplacementAndPreservesCurrentOwner() async throws {
        let url = try fixture()
        let state = FileState()
        let session = try await state.recordExternalFileRead(original, at: url)
        state.installExternalSaveSession(session)
        try saved.write(to: url)
        let gate = ReloadReceiptGate()
        var abandoned: UUID?
        let reload = Task {
            try await state.prepareExternalFileReload { owner, pending in
                let result = try await ExternalFileSaveCoordinator.shared.prepareReload(
                    at: url, session: owner.session, hasPendingCanvasEdits: pending
                )
                abandoned = result?.session
                try await gate.pause()
                return result
            }
        }
        await gate.waitUntilPaused()
        state.installExternalSaveSession(UUID())
        state.reportExternalSaveFailure(CocoaError(.fileWriteNoPermission), at: url, force: true)
        let current = state.terminationSaveToken
        let liveError = state.externalSaveErrorMessage
        await gate.release()
        do { _ = try await reload.value; XCTFail("A stale result must cancel") }
        catch is CancellationError { }
        XCTAssertEqual(state.terminationSaveToken, current)
        XCTAssertEqual(state.externalSaveErrorMessage, liveError)
        let replacement = try XCTUnwrap(abandoned)
        do {
            try await ExternalFileSaveCoordinator.shared.forkSession(at: url, from: replacement, to: UUID())
            XCTFail("The discarded replacement baseline must be released")
        } catch is ExternalFileSaveFailure { }
        XCTAssertEqual(try Data(contentsOf: url), saved)
        await ExternalFileSaveCoordinator.shared.releaseSession(session)
    }

    @MainActor
    func testStaleReadErrorBecomesCancellationWithoutReplacingCurrentError() async throws {
        let url = try fixture()
        let state = FileState()
        let gate = ReloadReceiptGate()
        let reload = Task {
            try await state.prepareExternalFileReload { _, _ in
                try await gate.pause()
                throw CocoaError(.fileReadNoPermission)
            }
        }
        await gate.waitUntilPaused()
        state.installExternalSaveSession(UUID())
        state.reportExternalSaveFailure(CocoaError(.fileWriteNoPermission), at: url, force: true)
        let current = state.terminationSaveToken
        let liveError = state.externalSaveErrorMessage
        await gate.release()
        do { _ = try await reload.value; XCTFail("A stale read error must cancel") }
        catch is CancellationError { }
        XCTAssertEqual(state.terminationSaveToken, current)
        XCTAssertEqual(state.externalSaveErrorMessage, liveError)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testCurrentOwnerReadErrorStillPropagates() async throws {
        let state = FileState()
        let owner = state.terminationSaveToken
        do {
            _ = try await state.prepareExternalFileReload { _, _ in throw CocoaError(.fileReadNoPermission) }
            XCTFail("A current read failure must not become cancellation")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadNoPermission) }
        XCTAssertEqual(state.terminationSaveToken, owner)
    }

    func testSaveCompletingAfterReadForcesAFreshVersionBeforeComparison() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        let reads = ReloadReadCounter()
        let saved = saved
        let replacement = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true, reader: { target in
            let version = try await ExternalFileVersion.read(at: target)
            if await reads.next() == 1 {
                try await coordinator.save(saved, to: target, session: session, writer: ExternalFileWriter.write)
            }
            return version
        })
        XCTAssertNil(replacement)
        let count = await reads.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testReadWaitsForWrittenBytesToReceiveTheirOwnSaveReceipt() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        let gate = ReloadReceiptGate()
        let save = Task {
            try await coordinator.save(saved, to: url, session: session) { content, target, baseline in
                let receipt = try await ExternalFileWriter.write(content, to: target, replacing: baseline)
                try await gate.pause()
                return receipt
            }
        }
        await gate.waitUntilPaused()
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let entered = XCTestExpectation(description: "Reload started")
        let finished = XCTestExpectation(description: "No admission before receipt")
        finished.isInverted = true
        let reload = Task {
            entered.fulfill()
            let result = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true)
            finished.fulfill()
            return result
        }
        await fulfillment(of: [entered], timeout: 1)
        await fulfillment(of: [finished], timeout: 0.1)
        await gate.release()
        try await save.value
        let replacement = try await reload.value
        XCTAssertNil(replacement)
        try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testContinuallySupersededReadCancelsWithoutAdoptingAStaleVersion() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        let reads = ReloadReadCounter()
        do {
            _ = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true, reader: { target in
                let version = try await ExternalFileVersion.read(at: target)
                let count = await reads.next()
                try await coordinator.save(Data("save-\(count)".utf8), to: target, session: session, writer: ExternalFileWriter.write)
                return version
            })
            XCTFail("An unsettled read cannot install a replacement session")
        } catch is CancellationError { }
        let count = await reads.count
        XCTAssertEqual(count, 3)
        XCTAssertEqual(try Data(contentsOf: url), Data("save-3".utf8))
        try await coordinator.save(latest, to: url, session: session, writer: ExternalFileWriter.write)
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }

    func testNewQueuedWriterAfterFirstWaitMustPublishItsReceiptBeforeReload() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        let firstGate = ReloadReceiptGate()
        let secondGate = ReloadReceiptGate()
        let first = Task {
            try await coordinator.save(saved, to: url, session: session) { content, target, baseline in
                let receipt = try await ExternalFileWriter.write(content, to: target, replacing: baseline)
                try await firstGate.pause()
                return receipt
            }
        }
        await firstGate.waitUntilPaused()
        let reads = ReloadReadCounter()
        let resumes = ReloadReadCounter()
        let selectedA = ReloadReceiptGate()
        let resumedA = XCTestExpectation(description: "Reload resumes A while B receipt is held")
        let finished = XCTestExpectation(description: "Reload waits for B receipt")
        finished.isInverted = true
        let reload = Task {
            let result = try await coordinator.prepareReload(
                at: url, session: session, hasPendingCanvasEdits: true,
                observeWriteWait: { phase in
                    switch phase {
                        case .selected:
                            if await reads.next() == 1 { try await selectedA.pause() }
                        case .finished:
                            if await resumes.next() == 1 {
                                await secondGate.waitUntilPaused()
                                resumedA.fulfill()
                            }
                    }
                }
            )
            finished.fulfill()
            return result
        }
        await selectedA.waitUntilPaused()
        let second = Task {
            try await coordinator.save(latest, to: url, session: session) { content, target, baseline in
                let receipt = try await ExternalFileWriter.write(content, to: target, replacing: baseline)
                try await secondGate.pause()
                return receipt
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await coordinator.pendingContent(at: url, session: session) != latest {
            guard ContinuousClock.now < deadline else { throw ReloadReceiptError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
        await selectedA.release()
        await firstGate.release()
        await fulfillment(of: [resumedA], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: url), latest)
        await fulfillment(of: [finished], timeout: 0.1)
        await secondGate.release()
        try await first.value
        try await second.value
        let replacement = try await reload.value
        XCTAssertNil(replacement)
    }

    func testWriterStartingDuringReadMustFinishBeforeItsBytesAreCompared() async throws {
        let url = try fixture()
        let coordinator = ExternalFileSaveCoordinator()
        let session = UUID()
        _ = await coordinator.recordRead(try read(url), at: url, session: session)
        let startWrite = ReloadReceiptGate()
        let receiptGate = ReloadReceiptGate()
        let readReturned = XCTestExpectation(description: "Read contains B before B receipt")
        let finished = XCTestExpectation(description: "Reload waits for the receipt after reading B")
        finished.isInverted = true
        let save = Task {
            try await startWrite.pause()
            try await coordinator.save(saved, to: url, session: session) { content, target, baseline in
                let receipt = try await ExternalFileWriter.write(content, to: target, replacing: baseline)
                try await receiptGate.pause()
                return receipt
            }
        }
        let reads = ReloadReadCounter()
        let reload = Task {
            let result = try await coordinator.prepareReload(at: url, session: session, hasPendingCanvasEdits: true, reader: { target in
                let firstRead = await reads.next() == 1
                if firstRead {
                    await startWrite.release()
                    await receiptGate.waitUntilPaused()
                }
                let version = try await ExternalFileVersion.read(at: target)
                if firstRead { readReturned.fulfill() }
                return version
            })
            finished.fulfill()
            return result
        }
        await fulfillment(of: [readReturned], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        await fulfillment(of: [finished], timeout: 0.1)
        await receiptGate.release()
        try await save.value
        let replacement = try await reload.value
        XCTAssertNil(replacement)
        let count = await reads.count
        XCTAssertGreaterThanOrEqual(count, 2)
    }
}

private actor ReloadReadCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private enum ReloadReceiptError: Error { case timeout }

private actor ReloadReceiptGate {
    private nonisolated let entered = XCTestExpectation(description: "Bytes written, receipt held")
    private var released = false

    func pause() async throws {
        entered.fulfill()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw ReloadReceiptError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    nonisolated func waitUntilPaused() async {
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func release() { released = true }
}
