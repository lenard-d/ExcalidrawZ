import XCTest
@testable import ExcalidrawZ

final class ExcalidrawDocumentContentSnapshotSchedulerTests: XCTestCase {
    func testCancelledLifecycleWaitDoesNotAcknowledgeInFlightSave() async {
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: {})
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "captured-target", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        let wait = Task { await scheduler.waitForCommitToFinish() }
        wait.cancel()
        let completed = await wait.value
        XCTAssertFalse(completed)
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
        // The actual writer later confirms its outcome, independently of the cancelled waiter.
        scheduler.markCommitted(snapshotRevision: 7, fallbackRevision: nil)
        scheduler.completeScheduledCommit()
        let afterWrite = await scheduler.waitForCommitToFinish()
        XCTAssertTrue(afterWrite)
        XCTAssertFalse(scheduler.hasPendingDirtySnapshot())
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

    func testFailedSaveStaysDirtyForLifecycleRetry() async {
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler(onScheduledCommit: {})
        defer { scheduler.reset() }
        scheduler.recordPendingContentDirty(fileID: "captured-target", revision: 7)
        XCTAssertNotNil(scheduler.takeScheduledCommitState())
        // A failed write completes the attempt without marking its revision committed.
        scheduler.completeScheduledCommit()
        let completed = await scheduler.waitForCommitToFinish()
        XCTAssertTrue(completed)
        XCTAssertEqual(scheduler.takeFlushState()?.expectedRevision, 7)
    }
}
