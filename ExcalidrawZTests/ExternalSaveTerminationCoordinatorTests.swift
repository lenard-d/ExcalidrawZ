import Foundation
import XCTest
@testable import ExcalidrawZ

final class ExternalSaveTerminationCoordinatorTests: XCTestCase {
    @MainActor
    private final class Window: ExternalSaveTerminationParticipant {
        let session = UUID()
        var revision: UInt64 = 0
        var saveSucceeds = true
        var hasPendingExternalSnapshot = false
        var onFlush: (() -> Void)?
        var flushCount = 0

        var terminationSaveToken: ExternalSaveTerminationToken {
            ExternalSaveTerminationToken(fileID: "drawing", session: session, editRevision: revision)
        }

        func flushPendingCanvasSnapshotBeforeTermination() async -> Bool {
            flushCount += 1
            onFlush?()
            return saveSucceeds
        }
    }

    @MainActor
    func testCleanSecondWindowCannotHideFirstWindowsFailure() async {
        let coordinator = ExternalSaveTerminationCoordinator()
        let failed = Window()
        failed.saveSucceeds = false
        let clean = Window()
        coordinator.register(failed)
        coordinator.register(clean)
        let canQuit = await coordinator.flush()
        XCTAssertFalse(canQuit)
        XCTAssertEqual(failed.flushCount, 1)
        XCTAssertFalse(coordinator.canConfirmTermination)
    }

    @MainActor
    func testEditDuringAnotherWindowsFlushRejectsQuit() async {
        let coordinator = ExternalSaveTerminationCoordinator()
        let first = Window()
        let second = Window()
        first.onFlush = { [weak second] in second?.revision += 1 }
        second.onFlush = { [weak first] in first?.revision += 1 }
        coordinator.register(first)
        coordinator.register(second)
        let canQuit = await coordinator.flush()
        XCTAssertFalse(canQuit)
        XCTAssertEqual(first.flushCount, 1)
        XCTAssertEqual(second.flushCount, 1)
    }

    @MainActor
    func testEditDuringLaterBackupInvalidatesSuccessfulFlush() async {
        let coordinator = ExternalSaveTerminationCoordinator()
        let window = Window()
        coordinator.register(window)
        let canQuit = await coordinator.flush()
        XCTAssertTrue(canQuit)
        window.revision += 1
        XCTAssertFalse(coordinator.canConfirmTermination)
    }

    @MainActor
    func testPendingSnapshotPreventsQuitEvenWhenFlushReturnsSuccess() async {
        let coordinator = ExternalSaveTerminationCoordinator()
        let window = Window()
        window.hasPendingExternalSnapshot = true
        coordinator.register(window)
        let canQuit = await coordinator.flush()
        XCTAssertFalse(canQuit)
    }

    @MainActor
    func testClosedWindowIsNotRetainedByRegistry() async {
        let coordinator = ExternalSaveTerminationCoordinator()
        var window: Window? = Window()
        window?.onFlush = { XCTFail("A closed window must not remain in the registry") }
        coordinator.register(window!)
        window = nil
        let canQuit = await coordinator.flush()
        XCTAssertTrue(canQuit)
    }
}
