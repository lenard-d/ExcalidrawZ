import XCTest
@testable import ExcalidrawZ

final class ExcalidrawDocumentContentSnapshotSchedulerTests: XCTestCase {
    func testCancelledLifecycleWaitDoesNotAcknowledgeInFlightSave() async throws {
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: {})
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
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: {})
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
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: {})
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
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: {})
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
