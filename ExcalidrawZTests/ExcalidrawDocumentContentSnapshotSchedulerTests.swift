import XCTest
@testable import ExcalidrawZ

final class ExcalidrawDocumentContentSnapshotSchedulerTests: XCTestCase {
    func testCompletionAdvancesPendingRevisionWithoutWaitingForPeriodicThrottle() async throws {
        let called = expectation(description: "Completed content is scheduled")
        let recorded = ScheduledContentCommits()
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler { state in
            await recorded.append(state)
            called.fulfill()
        }
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        scheduler.markCommitted(snapshotRevision: 7, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 8)
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 8)
        await fulfillment(of: [called], timeout: 0.5)
        let states = await recorded.states
        XCTAssertEqual(states.map(\.expectedRevision), [8])
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot(), "Scheduling must not acknowledge the write")
        scheduler.markCommitted(snapshotRevision: 8, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
    }

    func testCompletionDuringWriteRetainsLatestRevisionWithoutStartingAnotherWrite() async throws {
        let called = expectation(description: "Latest content follows the actual in-flight result")
        let recorded = ScheduledContentCommits()
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler { state in
            await recorded.append(state)
            called.fulfill()
        }
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 8)
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 8)
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 8)
        XCTAssertNil(scheduler.takeScheduledCommitState(), "The held write owns the snapshot operation")
        let before = await recorded.states
        XCTAssertTrue(before.isEmpty)
        scheduler.markCommitted(snapshotRevision: 7, fallbackRevision: nil)
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
        scheduler.completeScheduledCommit()
        await fulfillment(of: [called], timeout: 0.5)
        let after = await recorded.states
        XCTAssertEqual(after.map(\.expectedRevision), [8])
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
    }

    func testStaleOrDifferentOwnerCompletionDoesNotAdvanceActiveInputCadence() async throws {
        let unexpected = expectation(description: "Ordinary pending content keeps its periodic deadline")
        unexpected.isInverted = true
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler { _ in unexpected.fulfill() }
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        scheduler.markCommitted(snapshotRevision: 7, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 9)
        scheduler.requestCompletedContentCommit(fileID: "other-owner", revision: 9)
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 8)
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertEqual(scheduler.takeFlushState()?.expectedRevision, 9)
    }

    func testMetadataRevisionDoesNotEraseInheritedCompletedContent() async throws {
        let called = expectation(description: "Inherited content remains eligible")
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler { _ in called.fulfill() }
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 9)
        scheduler.recordLatestRevision(10)
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 9)
        await fulfillment(of: [called], timeout: 0.5)
        scheduler.markCommitted(snapshotRevision: 9, fallbackRevision: nil)
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
        scheduler.markCommitted(snapshotRevision: 10, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
    }

    func testCleanCompletionDoesNotCreateOrAcknowledgeContent() async throws {
        let unexpected = expectation(description: "A timing hint cannot create dirty work")
        unexpected.isInverted = true
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler { _ in unexpected.fulfill() }
        defer { scheduler.reset() }
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 9)
        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
    }

    func testNewActiveInputWithdrawsQueuedCompletionWhilePreviousWriteFinishes() async throws {
        let unexpected = expectation(description: "New active input retains the ordinary periodic deadline")
        unexpected.isInverted = true
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler { _ in unexpected.fulfill() }
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 8)
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 8)
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 9)
        scheduler.markCommitted(snapshotRevision: 7, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertEqual(scheduler.takeFlushState()?.expectedRevision, 9)
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
    }

    func testResetDiscardsOldCompletionWithoutAdvancingReplacementOwner() async throws {
        let unexpected = expectation(description: "Old completion cannot accelerate replacement content")
        unexpected.isInverted = true
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler { _ in unexpected.fulfill() }
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "owner", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 7)
        scheduler.reset()
        scheduler.recordPendingContentDirty(fileID: "replacement", revision: 1)
        scheduler.requestCompletedContentCommit(fileID: "owner", revision: 7)
        await fulfillment(of: [unexpected], timeout: 0.1)
        let pending = scheduler.takeFlushState()
        XCTAssertEqual(pending?.expectedFileID, "replacement")
        XCTAssertEqual(pending?.expectedRevision, 1)
    }

    func testCancelledLifecycleWaitDoesNotAcknowledgeInFlightSave() async throws {
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: { _ in })
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "captured-target", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        let wait = Task { await scheduler.waitForCommitToFinish() }
        defer { wait.cancel() }
        wait.cancel()
        let completed = try await boundedSaveTestValue(wait)
        XCTAssertFalse(completed)
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
        // The actual writer later confirms its outcome, independently of the cancelled waiter.
        scheduler.markCommitted(snapshotRevision: 7, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        let afterWriteWait = Task { await scheduler.waitForCommitToFinish() }
        defer { afterWriteWait.cancel() }
        let afterWrite = try await boundedSaveTestValue(afterWriteWait)
        XCTAssertTrue(afterWrite)
        XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
    }

    func testUnfinishedSchedulerWaitTimesOutWithoutAcknowledgingAndCanBeCleanedUp() async throws {
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: { _ in })
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "captured-target", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        let wait = Task { await scheduler.waitForCommitToFinish() }
        defer { wait.cancel() }
        do {
            _ = try await boundedSaveTestValue(wait, timeout: .milliseconds(20))
            XCTFail("The actual scheduler still has an in-flight write")
        } catch SaveTestWaitError.timedOut { }
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
        // Release simulated writer ownership. Timeout cancellation must not acknowledge it.
        scheduler.completeScheduledCommit()
        let completed = try await boundedSaveTestValue(wait)
        XCTAssertFalse(completed)
        XCTAssertEqual(scheduler.takeFlushState()?.expectedRevision, 7)
    }

    func testOlderSuccessfulSaveCannotClearNewerDirtyRevision() {
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: { _ in })
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "captured-target", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        scheduler.recordPendingContentDirty(fileID: "captured-target", revision: 8)
        scheduler.markCommitted(snapshotRevision: 7, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        let pending = scheduler.takeFlushState()
        XCTAssertEqual(pending?.expectedRevision, 8)
        XCTAssertEqual(pending?.expectedFileID, "captured-target")
        scheduler.markCommitted(snapshotRevision: 8, fallbackRevision: nil)
        XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
    }

    func testFailedSaveStaysDirtyForLifecycleRetry() async throws {
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: { _ in })
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "captured-target", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        // A failed write completes the attempt without marking its revision committed.
        scheduler.completeScheduledCommit()
        let wait = Task { await scheduler.waitForCommitToFinish() }
        defer { wait.cancel() }
        let completed = try await boundedSaveTestValue(wait)
        XCTAssertTrue(completed)
        XCTAssertEqual(scheduler.takeFlushState()?.expectedRevision, 7)
    }
}

private actor ScheduledContentCommits {
    private(set) var states: [ExcalidrawDocumentContentSnapshotScheduler.CommitState] = []
    func append(_ state: ExcalidrawDocumentContentSnapshotScheduler.CommitState) { states.append(state) }
}
