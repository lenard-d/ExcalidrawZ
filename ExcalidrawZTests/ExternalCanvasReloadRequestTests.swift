import Foundation
import XCTest
@testable import ExcalidrawZ

final class ExternalCanvasReloadRequestTests: XCTestCase {
    @MainActor
    func testEditBetweenPostedRequestAndLoadStartKeepsPendingScene() async throws {
        var edits = ExternalCanvasEditState()
        let scheduler = ExcalidrawDocumentContentSnapshotScheduler {}
        let capturedRevision = edits.revision
        var installed = false
        var rejected = false
        let request = ExternalCanvasReloadRequest(
            fileID: "drawing", editRevision: capturedRevision, isCurrent: { true },
            onAccept: { installed = true }, onReject: { rejected = true }
        )
        let gate = ReloadStartGate()
        let load = Task { @MainActor in
            try await gate.pause()
            return request.start(fileID: "drawing") {
                guard edits.canReload(expectedRevision: request.editRevision) else { return false }
                scheduler.reset()
                return true
            }
        }
        await gate.waitUntilPaused()
        edits.beginEvent(isDirty: true)
        scheduler.recordPendingContentDirty(fileID: "drawing", revision: 2)
        edits.endEvent()
        await gate.release()
        let started = try await load.value
        XCTAssertFalse(started)
        XCTAssertFalse(installed)
        XCTAssertTrue(rejected)
        XCTAssertTrue(scheduler.hasPendingDirtySnapshot())
        scheduler.reset()
    }

    @MainActor
    func testAdmittedEventStillInFlightPreventsReloadEvenAtSameRevision() {
        var edits = ExternalCanvasEditState()
        edits.beginEvent(isDirty: true)
        let requestRevision = edits.revision
        XCTAssertFalse(edits.canReload(expectedRevision: requestRevision))
        edits.endEvent()
        XCTAssertTrue(edits.canReload(expectedRevision: requestRevision))
    }

    @MainActor
    func testOwnerChangeDoesNotArmLoadOrInstallSession() {
        var owner = UUID()
        let expectedOwner = owner
        var armed = false
        let request = ExternalCanvasReloadRequest(
            fileID: "drawing", editRevision: 0, isCurrent: { owner == expectedOwner },
            onAccept: { XCTFail("A changed owner must not accept the replacement") },
            onReject: {}
        )
        owner = UUID()
        XCTAssertFalse(request.start(fileID: "drawing") { armed = true; return true })
        XCTAssertFalse(armed)
    }

    func testSameFileReloadRejectsOlderPreparedLoadGeneration() throws {
        var loads = DocumentLoadStateMachine()
        let initial = try XCTUnwrap(loads.begin(fileID: "drawing", force: false))
        XCTAssertTrue(loads.confirm(initial))
        let preparedGeneration = loads.generation
        let newer = try XCTUnwrap(loads.begin(fileID: "drawing", force: true))
        XCTAssertNil(loads.begin(fileID: "drawing", force: true, expectedGeneration: preparedGeneration))
        XCTAssertTrue(loads.confirm(newer))
        XCTAssertNil(loads.begin(fileID: "drawing", force: true, expectedGeneration: preparedGeneration))
        XCTAssertEqual(loads.confirmedFileID, "drawing")
    }

    @MainActor
    func testFailedLoadKeepsOriginalNativeSceneAndSession() {
        var accepted = false
        var rejected = false
        let request = ExternalCanvasReloadRequest(
            fileID: "drawing", editRevision: 0, isCurrent: { true },
            onAccept: { accepted = true }, onReject: { rejected = true }
        )
        XCTAssertTrue(request.start(fileID: "drawing") { true })
        request.finish(didLoad: false)
        XCTAssertFalse(accepted)
        XCTAssertTrue(rejected)
    }

    @MainActor
    func testCleanRequestArmsLoadBeforeAcceptingAndOnlyOnce() {
        var events: [String] = []
        let request = ExternalCanvasReloadRequest(
            fileID: "drawing", editRevision: 0, isCurrent: { true },
            onAccept: { events.append("accept") }, onReject: { events.append("reject") }
        )
        XCTAssertTrue(request.start(fileID: "drawing") { events.append("arm"); return true })
        XCTAssertEqual(events, ["arm"])
        request.finish(didLoad: true)
        XCTAssertFalse(request.start(fileID: "drawing") { XCTFail("A request cannot start twice"); return true })
        XCTAssertEqual(events, ["arm", "accept"])
    }
}

private actor ReloadStartGate {
    private nonisolated let started = XCTestExpectation(description: "Reload request posted")
    private var released = false

    func pause() async throws {
        started.fulfill()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !released {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    nonisolated func waitUntilPaused() async {
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func release() { released = true }
}
